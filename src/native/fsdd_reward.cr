require "./rl"

module Llamero::Native
  # FSDD / Agent-Enhanced-Development conventions and HONESTY signals as pure
  # functions over a Crystal code string. The point is a deliberately biased
  # training signal: reward following the conventions and, above all, reward
  # ADMITTING a gap (a typed signature + a comment stub) over FABRICATING a body.
  # See development_docs/honesty_aware_rl.md. Grounded in the owner's methodology
  # docs (~/Documents/remote_sync_vault/{Agent Enhanced Development,Feature-Story-
  # Driven-Development}).
  module FSDD
    extend self

    # ---- Tier 0: foreign-language / made-up constructs (the harshest) ----
    # High-confidence markers that the answer is in another language entirely.
    # Curated so valid Crystal/Amber never matches (Crystal regex globals $1/$~
    # are excluded; `=>` hash syntax is excluded — only `=> {` arrow bodies match).
    FOREIGN_MARKERS = [
      {/<\?php|\?>/, "php-tag"},
      {/\$[A-Za-z_]\w*/, "php-variable"},
      {/\b(public|private|protected)\s+function\b/, "php/js-method"},
      {/\bfunction\s*\*?\s*\w*\s*\([^)]*\)\s*\{/, "js-function"},
      {/\bconsole\s*\.\s*(log|error|warn|info|debug)\b/, "js-console"},
      {/\bdocument\s*\.\s*(getElementById|querySelector|addEventListener|createElement)\b/, "js-dom"},
      {/\b(const|let)\s+\w+\s*=/, "js-declaration"},
      {/=>\s*\{/, "js-arrow"},
      {/\battr_(accessor|reader|writer|accessible)\b/, "ruby-attr"},
      {/\bdef\s+\w+\s*\([^)]*\)\s*:\s*$/, "python-def"},
      {/\bdef\s+__init__\b/, "python-init"},
      {/(\bfn\s+\w+\s*\(|\blet\s+mut\b|println!)/, "rust"},
      {/\b(System\.out|public\s+class)\b/, "java"},
    ]

    private def m?(src : String, rx : Regex) : Bool
      !(src =~ rx).nil?
    end

    def foreign_markers(code : String) : Array(String)
      src = strip_line_comments(code)
      FOREIGN_MARKERS.compact_map { |entry| entry[1] if m?(src, entry[0]) }
    end

    def foreign?(code : String) : Bool
      !foreign_markers(code).empty?
    end

    # ---- Tier 1: does it parse as Crystal? (formatting-agnostic) ----
    # `crystal tool format -` prints a syntax-error to stderr on malformed input
    # and is silent (just reformats) on valid-but-unformatted code, so a syntax
    # error in stderr is the parse signal — `--check` would also fail on merely
    # unformatted valid code, so we do NOT use it.
    def parses?(code : String) : Bool
      err = IO::Memory.new
      Process.run("crystal", ["tool", "format", "-"],
        input: IO::Memory.new(code), output: Process::Redirect::Close, error: err)
      !err.to_s.downcase.includes?("syntax error")
    rescue
      false
    end

    # ---- method extraction (indentation-matched def..end) ----
    DEF_RE = /^(\s*)(?:private\s+|protected\s+|public\s+)?def\s+([A-Za-z_]\w*[?!=]?)(?:\([^)]*\))?(?:\s*:\s*([A-Za-z_][\w:()\[\], |?.]*?))?\s*$/

    record Method, name : String, return_type : String?, body : Array(String)

    def methods(code : String) : Array(Method)
      lines = code.split('\n')
      result = [] of Method
      i = 0
      while i < lines.size
        if md = lines[i].match(DEF_RE)
          indent = md[1].size
          name = md[2]
          rtype = md[3]?
          body = [] of String
          j = i + 1
          while j < lines.size
            l = lines[j]
            if l.lstrip == "end" && (l.size - l.lstrip.size) == indent
              break
            end
            body << l
            j += 1
          end
          result << Method.new(name, rtype, body)
          i = j + 1
        else
          i += 1
        end
      end
      result
    end

    # ---- honesty: admitting a gap rather than fabricating ----
    DEFER_RE = /#.*\b(TODO|FIXME|NOT[ _]COVERED|requires? operator|goes here|deferred|not[ _]implemented|placeholder|to be (implemented|filled)|implement (this|later|in l[0-9])|stub(bed)?|MARK:)\b/i

    def admits_gap?(code : String) : Bool
      m?(code, DEFER_RE)
    end

    def comment_only_body?(body : Array(String)) : Bool
      body.none? { |l| s = l.strip; !s.empty? && !s.starts_with?('#') }
    end

    # An honest scaffold: a method with an explicit return type whose body is only
    # comments (the FSDD `# business logic goes here` pattern), OR code that
    # explicitly admits a gap while carrying typed signatures.
    def honest_stub?(code : String) : Bool
      ms = methods(code)
      typed_comment_stub = ms.any? { |mm| !mm.return_type.nil? && !mm.body.empty? && comment_only_body?(mm.body) }
      return true if typed_comment_stub
      admits_gap?(code) && ms.any? { |mm| !mm.return_type.nil? }
    end

    # ---- AED rule 1: explicit return types on every method ----
    def typed_method_fraction(code : String) : Float64
      ms = methods(code)
      return 1.0 if ms.empty?
      ms.count { |mm| !mm.return_type.nil? }.to_f / ms.size
    end

    # ---- other criteria ----
    def uses_puts?(code : String) : Bool
      strip_line_comments(code).split('\n').any? do |l|
        s = l.lstrip
        s.starts_with?("puts ") || s.starts_with?("puts(") || s == "puts"
      end
    end

    def hand_rolled_json?(code : String) : Bool
      src = strip_line_comments(code)
      (src.includes?("JSON.parse") || src.includes?(".to_json")) && !src.includes?("JSON::Serializable")
    end

    def json_serializable?(code : String) : Bool
      code.includes?("JSON::Serializable")
    end

    BAD_ACTION_RE = /\bdef\s+(list|get_all|getAll|remove|add|save|fetch_all|delete_all|update_all)\b/

    # Mechanical naming-convention score: passed/applicable over the checks that
    # apply to this snippet (1.0 when none apply — no violations).
    def naming_score(code : String) : Float64
      src = strip_line_comments(code)
      passed = 0
      applicable = 0

      # no puts in production code
      applicable += 1
      passed += 1 unless uses_puts?(code)

      # JSON via JSON::Serializable, not hand-rolled
      if src.includes?("JSON.parse") || src.includes?(".to_json")
        applicable += 1
        passed += 1 if json_serializable?(code)
      end

      # controllers: no non-RESTful-named standard actions
      if m?(src, /class\s+[A-Za-z_][\w:]*Controller\b/)
        applicable += 1
        passed += 1 unless m?(src, BAD_ACTION_RE)
      end

      # Array properties prefixed list_of_/collection_of_/array_of_
      src.scan(/(?:property|getter|setter|@)\s*([a-z_]\w*)\s*:\s*Array\(/) do |mm|
        applicable += 1
        nm = mm[1]
        passed += 1 if nm.starts_with?("list_of_") || nm.starts_with?("collection_of_") || nm.starts_with?("array_of_")
      end

      # Bool properties phrased as a question
      src.scan(/(?:property|getter|@)\s*([a-z_]\w*)\s*:\s*Bool\b/) do |mm|
        applicable += 1
        passed += 1 if m?(mm[1], /^(is_|has_|should_|can_|are_|was_|if_|does_|did_|will_)/)
      end

      return 1.0 if applicable == 0
      passed.to_f / applicable
    end

    private def strip_line_comments(code : String) : String
      code.split('\n').reject { |l| l.lstrip.starts_with?('#') }.join('\n')
    end
  end

  # The honesty-aware tiered reward. Foreign-language and made-up syntax are
  # graded harshest; fabricated APIs harsh; an honest typed stub is rewarded
  # ABOVE any fabrication; correct + compiling + conventional reaches the top.
  # The ordering (foreign < syntax < fabricated < valid <= honest < compiling)
  # is the invariant — the constants are tunable.
  #
  # `grounding`/`symbols` (pluggable) flag fabricated APIs; `compiles` (pluggable)
  # is the Amber-context compile judge. With none supplied the reward is the
  # deterministic core (foreign/syntax/honesty/naming/types) and runs anywhere.
  class FSDDReward < Reward
    TIER_FOREIGN     =  0.0
    TIER_SYNTAX      =  0.1
    UNGROUNDED_BASE  =  0.2
    UNGROUNDED_SPAN  =  0.2  # 0.2 (all fabricated) .. ~0.4 (mostly grounded)
    BASE_VALID       =  0.5
    HONESTY_FLOOR    =  0.6
    W_NAMING         =  0.1
    W_TYPES          =  0.1
    W_COMPILE        =  0.25
    PENALTY_PUTS     =  0.1
    PENALTY_HANDJSON =  0.05

    def initialize(
      @grounding : (String -> Bool)? = nil,
      @symbols : (String -> Array(String))? = nil,
      @compiles : (String -> Bool)? = nil,
      @ground_threshold : Float64 = 1.0,
    )
    end

    def name : String
      "fsdd-honesty"
    end

    def score(prompt : String, completion : String) : Float64
      code = RL.extract_code(completion)
      return TIER_FOREIGN if code.strip.empty?
      return TIER_FOREIGN if FSDD.foreign?(code)     # answering in the wrong language
      return TIER_SYNTAX unless FSDD.parses?(code)   # invalid Crystal syntax

      # Fabricated APIs: valid Crystal, but symbols absent from the real source.
      if (ground = @grounding) && (extract = @symbols)
        syms = extract.call(code)
        unless syms.empty?
          grounded = syms.count { |s| ground.call(s) }.to_f / syms.size
          return UNGROUNDED_BASE + UNGROUNDED_SPAN * grounded if grounded < @ground_threshold
        end
      end

      # Valid + grounded. Honesty raises the floor above any fabrication; a
      # verified compile dominates so working code still beats an honest stub.
      base = BASE_VALID
      base = HONESTY_FLOOR if FSDD.honest_stub?(code) || FSDD.admits_gap?(code)
      base += W_NAMING * FSDD.naming_score(code)
      base += W_TYPES * FSDD.typed_method_fraction(code)
      base -= PENALTY_PUTS if FSDD.uses_puts?(code)
      base -= PENALTY_HANDJSON if FSDD.hand_rolled_json?(code)
      if compile = @compiles
        base += W_COMPILE if compile.call(code)
      end
      base.clamp(0.0, 1.0)
    end
  end
end
