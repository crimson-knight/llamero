require "./generation_mode"

module Llamero
  # Compile-time GBNF derivation from Crystal types, for grammar-constrained
  # decoding against the pinned llama.cpp build (see Llamero::LlamaCpp).
  #
  # The builder walks the exact same `T.instance_vars` reflection that powers
  # `JsonSchemaBuilder(T)`, so the JSON Schema (cloud/schema-prompt path) and
  # the GBNF grammar (llama.cpp path) can never disagree about a type's shape.
  # The entire grammar is computed at macro time and embedded as a string
  # literal - zero runtime cost.
  #
  # Guarantees and deliberate limits (v1):
  # - Output is JSON only, keys in declaration order (a documented contract of
  #   grammar mode). Anything the grammar admits parses with `T.from_json`.
  # - Optional (nilable) fields become an explicit subset alternation, capped
  #   at 6 optionals per object (2^6 = 64 alternatives) - never `x? x? x?`
  #   chains, which are a documented llama.cpp pathology (grammars/README,
  #   issue #4218).
  # - Recursive types are REFUSED (no bounded recursion in v1) - honest
  #   refusal beats a truncated-value lie and stays clear of upstream
  #   MAX_REPETITION_THRESHOLD = 2000 (src/llama-grammar.cpp:13).
  # - Over-budget or unsupported types: `T.to_gbnf` fails AT COMPILE TIME with
  #   the reason; `T.to_gbnf?` returns nil so `:auto` can fall back to
  #   schema-prompt with `T.gbnf_fallback_reason` explaining why.
  #
  # Complexity budget (initial numbers; revisited after the benchmark phase):
  #   max_rules: 128            max_nesting_depth: 8
  #   max_alternation_width_per_rule: 32 (enums/unions; the optional-subset
  #     alternation is governed by its own cap instead)
  #   max_total_alternatives: 256
  #   max_optional_fields_per_object: 6
  #   max_array_nesting: 4      max_union_members: 4
  #   recursion: forbidden
  #   estimated repetition product: v1 emits no bounded `{m,n}` repetitions at
  #     all, so the 1000 cap (< upstream 2000) is structurally satisfied.
  class GbnfBuilder(T)
    # One macro computes everything (budget analysis + grammar text) in a
    # single pass over the type graph, then expands differently per mode:
    #   :reason       -> String? (why grammar mode is refused, nil when OK)
    #   :build_or_nil -> String? (grammar text, nil when refused)
    #   :build        -> String  (grammar text, {% raise %} at compile time when refused)
    #
    # The graph walk is a bounded breadth-first pass (max_nesting_depth
    # rounds) with per-entry ancestor paths, so cycles are detected as data -
    # no unbounded macro recursion, no runaway generic instantiation.
    private macro gbnf_expand(mode)
      {% t0 = @type.type_vars.first.resolve %}

      {% max_depth = 8 %}
      {% max_rules = 128 %}
      {% max_total_alternatives = 256 %}
      {% max_optionals = 6 %}
      {% max_array_nesting = 4 %}
      {% max_union_members = 4 %}
      {% max_rule_width = 32 %}
      {% powers = [1, 2, 4, 8, 16, 32, 64, 128] %}
      {% core_names = ["ws", "string", "char", "hex", "int", "uint", "float", "bool", "null", "root"] %}

      {% reason = nil %}
      {% used_cores = ["ws"] %}
      {% object_rules = [] of Nil %} # {name, text}
      {% aux_rules = [] of Nil %}    # {name, text} - enum / array / hash productions
      {% processed = [] of Nil %}    # fully-qualified type names already emitted
      {% total_alternatives = 1 %}

      {% root_rule_name = nil %}
      {% frontier = [{t0, 1, [] of Nil}] %}

      {% if !(t0 < Llamero::BaseGrammar) %}
        {% reason = "#{t0.name} does not inherit from Llamero::BaseGrammar" %}
      {% end %}

      {% for round in (0..max_depth) %}
        {% next_frontier = [] of Nil %}
        {% for entry in frontier %}
          {% if reason == nil %}
            {% t = entry[0] %}
            {% depth = entry[1] %}
            {% path = entry[2] %}
            {% t_key = t.name.stringify %}
            {% if path.includes?(t_key) %}
              {% reason = "recursive type #{t_key.id} (recursion is refused in v1)" %}
            {% elsif depth > max_depth %}
              {% reason = "nesting depth exceeds #{max_depth}" %}
            {% elsif processed.includes?(t_key) %}
              {% skip = true %} # diamond reference: rule already emitted
            {% else %}
              {% processed << t_key %}
              {% rule_name = t_key.split("::").map(&.underscore).join("-").gsub(/_/, "-") %}
              {% if core_names.includes?(rule_name) %}
                {% rule_name = "t-#{rule_name.id}" %}
              {% end %}
              {% if root_rule_name == nil %}
                {% root_rule_name = rule_name %}
              {% end %}

              {% fields = [] of Nil %} # {json_key, value_production, optional?}
              {% optional_count = 0 %}

              {% for ivar in t.instance_vars %}
                {% if reason == nil %}
                  {% field_ann = ivar.annotation(::JSON::Field) %}
                  {% ignored = field_ann && field_ann[:ignore] %}
                  {% if !ignored %}
                    {% if field_ann && field_ann[:converter] %}
                      {% reason = "field #{t_key.id}##{ivar.name} uses a JSON converter; grammar cannot mirror custom converters" %}
                    {% else %}
                      {% json_key = field_ann && field_ann[:key] ? field_ann[:key].id.stringify : ivar.name.stringify %}
                      {% ft = ivar.type.resolve %}
                      {% field_nilable = ft.nilable? %}
                      {% members = ft.union_types.reject { |u| u == Nil } %}
                      {% value_prod = nil %}

                      {% if members.size > 1 %}
                        {% if members.size > max_union_members %}
                          {% reason = "union at #{t_key.id}##{ivar.name} has #{members.size} members (max #{max_union_members})" %}
                        {% elsif members.all? { |m| m <= Int8 || m <= Int16 || m <= Int32 || m <= Int64 || m <= UInt8 || m <= UInt16 || m <= UInt32 || m <= UInt64 || m <= Float32 || m <= Float64 } %}
                          {% if members.any? { |m| m <= Float32 || m <= Float64 } %}
                            {% value_prod = "float" %}
                          {% elsif members.any? { |m| m <= Int8 || m <= Int16 || m <= Int32 || m <= Int64 } %}
                            {% value_prod = "int" %}
                          {% else %}
                            {% value_prod = "uint" %}
                          {% end %}
                          {% used_cores << value_prod %}
                        {% else %}
                          {% reason = "union at #{t_key.id}##{ivar.name} is not on the allowlist (nilable or numeric widening only)" %}
                        {% end %}
                      {% else %}
                        {% wrappers = [] of Nil %} # {"arr"|"map", element_nilable}, outermost first
                        {% cur = members.first.resolve %}
                        {% terminal = nil %}

                        {% for _level in (0..max_array_nesting) %}
                          {% if reason == nil && terminal == nil %}
                            {% if cur < Array %}
                              {% if wrappers.size >= max_array_nesting %}
                                {% reason = "array/hash nesting at #{t_key.id}##{ivar.name} exceeds #{max_array_nesting}" %}
                              {% else %}
                                {% el = cur.type_vars.first.resolve %}
                                {% el_members = el.union_types.reject { |u| u == Nil } %}
                                {% if el_members.size > 1 %}
                                  {% reason = "union element inside Array at #{t_key.id}##{ivar.name} is not supported" %}
                                {% else %}
                                  {% wrappers << {"arr", el.nilable?} %}
                                  {% cur = el_members.first.resolve %}
                                {% end %}
                              {% end %}
                            {% elsif cur < Hash %}
                              {% if !(cur.type_vars.first.resolve <= String) %}
                                {% reason = "Hash keys at #{t_key.id}##{ivar.name} must be String" %}
                              {% elsif wrappers.size >= max_array_nesting %}
                                {% reason = "array/hash nesting at #{t_key.id}##{ivar.name} exceeds #{max_array_nesting}" %}
                              {% else %}
                                {% hv = cur.type_vars[1].resolve %}
                                {% hv_members = hv.union_types.reject { |u| u == Nil } %}
                                {% if hv_members.size > 1 %}
                                  {% reason = "union value inside Hash at #{t_key.id}##{ivar.name} is not supported" %}
                                {% else %}
                                  {% wrappers << {"map", hv.nilable?} %}
                                  {% cur = hv_members.first.resolve %}
                                {% end %}
                              {% end %}
                            {% else %}
                              {% terminal = cur %}
                            {% end %}
                          {% end %}
                        {% end %}

                        {% if reason == nil && terminal == nil %}
                          {% reason = "array/hash nesting at #{t_key.id}##{ivar.name} exceeds #{max_array_nesting}" %}
                        {% end %}

                        {% base_prod = nil %}
                        {% if reason == nil %}
                          {% if terminal <= String %}
                            {% base_prod = "string" %}
                            {% used_cores << "string" %}
                          {% elsif terminal <= Bool %}
                            {% base_prod = "bool" %}
                            {% used_cores << "bool" %}
                          {% elsif terminal <= Int8 || terminal <= Int16 || terminal <= Int32 || terminal <= Int64 %}
                            {% base_prod = "int" %}
                            {% used_cores << "int" %}
                          {% elsif terminal <= UInt8 || terminal <= UInt16 || terminal <= UInt32 || terminal <= UInt64 %}
                            {% base_prod = "uint" %}
                            {% used_cores << "uint" %}
                          {% elsif terminal <= Float32 || terminal <= Float64 %}
                            {% base_prod = "float" %}
                            {% used_cores << "float" %}
                          {% elsif terminal < ::Enum %}
                            {% if terminal.annotation(Flags) %}
                              {% reason = "flags enum #{terminal.name} at #{t_key.id}##{ivar.name} has no single-string JSON form" %}
                            {% elsif terminal.constants.size > max_rule_width %}
                              {% reason = "enum #{terminal.name} has #{terminal.constants.size} members (max alternation width #{max_rule_width})" %}
                            {% else %}
                              {% enum_rule = terminal.name.stringify.split("::").map(&.underscore).join("-").gsub(/_/, "-") %}
                              {% if core_names.includes?(enum_rule) %}
                                {% enum_rule = "t-#{enum_rule.id}" %}
                              {% end %}
                              {% unless aux_rules.any? { |r| r[0] == enum_rule } %}
                                {% lits = terminal.constants.map { |c| "\"\\\"" + c.stringify.underscore + "\\\"\"" } %}
                                {% aux_rules << {enum_rule, enum_rule + " ::= " + lits.join(" | ")} %}
                                {% total_alternatives = total_alternatives + terminal.constants.size %}
                              {% end %}
                              {% base_prod = enum_rule %}
                            {% end %}
                          {% elsif terminal < Llamero::BaseGrammar %}
                            {% nested_rule = terminal.name.stringify.split("::").map(&.underscore).join("-").gsub(/_/, "-") %}
                            {% if core_names.includes?(nested_rule) %}
                              {% nested_rule = "t-#{nested_rule.id}" %}
                            {% end %}
                            {% next_frontier << {terminal, depth + 1, path + [t_key]} %}
                            {% base_prod = nested_rule %}
                          {% else %}
                            {% reason = "unsupported type #{terminal.name} at #{t_key.id}##{ivar.name} (no JSON-validity-preserving GBNF production in v1)" %}
                          {% end %}
                        {% end %}

                        {% if reason == nil %}
                          {% prod = base_prod %}
                          {% for wi in (0...wrappers.size) %}
                            {% w = wrappers[wrappers.size - 1 - wi] %}
                            {% if w[1] %}
                              {% used_cores << "null" %}
                              {% total_alternatives = total_alternatives + 1 %}
                            {% end %}
                            {% item = w[1] ? "(" + prod + " | null)" : prod %}
                            {% aux_name = prod + (w[1] ? "-null" : "") + (w[0] == "arr" ? "-arr" : "-map") %}
                            {% if w[0] == "arr" %}
                              {% aux_text = aux_name + " ::= \"[\" ws (" + item + " (ws \",\" ws " + item + ")*)? ws \"]\"" %}
                            {% else %}
                              {% used_cores << "string" %}
                              {% aux_text = aux_name + " ::= \"{\" ws (string ws \":\" ws " + item + " (ws \",\" ws string ws \":\" ws " + item + ")*)? ws \"}\"" %}
                            {% end %}
                            {% unless aux_rules.any? { |r| r[0] == aux_name } %}
                              {% aux_rules << {aux_name, aux_text} %}
                            {% end %}
                            {% prod = aux_name %}
                          {% end %}
                          {% value_prod = prod %}
                        {% end %}
                      {% end %}

                      {% if reason == nil %}
                        {% if field_nilable %}
                          {% optional_count = optional_count + 1 %}
                          {% used_cores << "null" %}
                          {% total_alternatives = total_alternatives + 1 %}
                        {% end %}
                        {% fields << {json_key, value_prod, field_nilable} %}
                      {% end %}
                    {% end %}
                  {% end %}
                {% end %}
              {% end %}

              {% if reason == nil %}
                {% if optional_count > max_optionals %}
                  {% reason = "#{t_key.id} has #{optional_count} optional fields (max #{max_optionals}; 2^n subset alternation)" %}
                {% else %}
                  {% total_alternatives = total_alternatives + powers[optional_count] %}
                  {% variants = [] of Nil %}
                  {% for s in (0...powers[optional_count]) %}
                    {% parts = [] of Nil %}
                    {% oi = 0 %}
                    {% for f in fields %}
                      {% if f[2] %}
                        {% included = (s % powers[oi + 1]) >= powers[oi] %}
                        {% oi = oi + 1 %}
                      {% else %}
                        {% included = true %}
                      {% end %}
                      {% if included %}
                        {% vprod = f[2] ? "(" + f[1] + " | null)" : f[1] %}
                        {% parts << "\"\\\"" + f[0] + "\\\"\" ws \":\" ws " + vprod %}
                      {% end %}
                    {% end %}
                    {% if parts.empty? %}
                      {% variants << "\"{\" ws \"}\"" %}
                    {% else %}
                      {% variants << "\"{\" ws " + parts.join(" ws \",\" ws ") + " ws \"}\"" %}
                    {% end %}
                  {% end %}
                  {% object_rules << {rule_name, rule_name + " ::= " + variants.join(" | ")} %}
                {% end %}
              {% end %}
            {% end %}
          {% end %}
        {% end %}
        {% frontier = next_frontier %}
      {% end %}

      {% if reason == nil && !frontier.empty? %}
        {% reason = "nesting depth exceeds #{max_depth}" %}
      {% end %}

      {% if reason == nil %}
        {% if used_cores.includes?("string") %}
          {% used_cores << "char" %}
          {% used_cores << "hex" %}
        {% end %}
        {% core_rule_texts = {
             # Live-verified on the pinned build: an unbounded `[ \t\n\r]*` ws
             # rule lets small models run away emitting whitespace forever
             # (same reason llama.cpp's own json.gbnf bounds its ws). {0,20}
             # keeps pretty-printing legal and is the only bounded repetition
             # v1 emits (repetition product 20 << upstream threshold 2000).
             "ws"     => "ws ::= [ \\t\\n\\r]{0,20}",
             "string" => "string ::= \"\\\"\" char* \"\\\"\"",
             "char"   => "char ::= [^\"\\\\\\x00-\\x1F] | \"\\\\\" ([\"\\\\/bfnrt] | \"u\" hex hex hex hex)",
             "hex"    => "hex ::= [0-9a-fA-F]",
             "int"    => "int ::= \"-\"? (\"0\" | [1-9][0-9]*)",
             "uint"   => "uint ::= \"0\" | [1-9][0-9]*",
             "float"  => "float ::= \"-\"? (\"0\" | [1-9][0-9]*) (\".\" [0-9]+)? ([eE] [+-]? [0-9]+)?",
             "bool"   => "bool ::= \"true\" | \"false\"",
             "null"   => "null ::= \"null\"",
           } %}
        {% emitted_cores = ["ws", "string", "char", "hex", "int", "uint", "float", "bool", "null"].select { |n| used_cores.includes?(n) } %}
        {% rule_count = 1 + emitted_cores.size + object_rules.size + aux_rules.size %}
        {% if rule_count > max_rules %}
          {% reason = "grammar needs #{rule_count} rules (max #{max_rules})" %}
        {% elsif total_alternatives > max_total_alternatives %}
          {% reason = "grammar has ~#{total_alternatives} alternatives (max #{max_total_alternatives})" %}
        {% end %}
      {% end %}

      {% if reason == nil %}
        {% lines = ["root ::= " + root_rule_name] %}
        {% for n in emitted_cores %}
          {% lines << core_rule_texts[n] %}
        {% end %}
        {% for r in object_rules %}
          {% lines << r[1] %}
        {% end %}
        {% for r in aux_rules %}
          {% lines << r[1] %}
        {% end %}
        {% grammar_text = lines.join("\n") + "\n" %}
      {% end %}

      {% if mode == :reason %}
        {% if reason %}
          {{ reason }}
        {% else %}
          nil
        {% end %}
      {% elsif mode == :build_or_nil %}
        {% if reason %}
          nil
        {% else %}
          {{ grammar_text }}
        {% end %}
      {% else %}
        {% if reason %}
          {% raise "GBNF for #{t0.name} exceeds budget: #{reason.id}; use generation_mode :auto or :schema_prompt" %}
        {% else %}
          {{ grammar_text }}
        {% end %}
      {% end %}
    end

    # The GBNF grammar for T. REFUSES over-budget/unsupported types AT
    # COMPILE TIME with the reason in the error message.
    def build : String
      gbnf_expand(:build)
    end

    # The GBNF grammar for T, or nil when refused (used by :auto fallback -
    # never a compile error).
    def build? : String?
      gbnf_expand(:build_or_nil)
    end

    # Why grammar mode is refused for T, or nil when T is within budget.
    def fallback_reason : String?
      gbnf_expand(:reason)
    end

    def within_budget? : Bool
      fallback_reason.nil?
    end
  end
end
