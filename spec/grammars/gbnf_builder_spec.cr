require "../spec_helper"

# --- fixtures: the full supported type matrix ---

enum GbnfSpecPriority
  Low
  High
  VeryHigh
end

class GbnfSpecAddress < Llamero::BaseGrammar
  property city : String = ""
  property zip : String = ""

  def initialize(@city = "", @zip = "")
  end
end

class GbnfSpecMatrix < Llamero::BaseGrammar
  property name : String = ""
  property age : Int32 = 0
  property count : UInt16 = 0_u16
  property score : Float64 = 0.0
  property active : Bool = false
  property priority : GbnfSpecPriority = GbnfSpecPriority::Low
  property tags : Array(String) = [] of String
  property lookup : Hash(String, Int32) = {} of String => Int32
  property address : GbnfSpecAddress = GbnfSpecAddress.new
  property friends : Array(GbnfSpecAddress) = [] of GbnfSpecAddress
  property nickname : String? = nil

  def initialize
  end
end

class GbnfSpecRenamed < Llamero::BaseGrammar
  @[JSON::Field(key: "fullName")]
  property name : String = ""

  @[JSON::Field(ignore: true)]
  property internal : String = ""

  def initialize
  end
end

class GbnfSpecConverter < Llamero::BaseGrammar
  @[JSON::Field(converter: String::RawConverter)]
  property raw : String = ""

  def initialize
  end
end

class GbnfSpecRecursive < Llamero::BaseGrammar
  property value : Int32 = 0
  property child : GbnfSpecRecursive? = nil

  def initialize
  end
end

class GbnfSpecMutualA < Llamero::BaseGrammar
  property b : GbnfSpecMutualB? = nil

  def initialize
  end
end

class GbnfSpecMutualB < Llamero::BaseGrammar
  property a : GbnfSpecMutualA? = nil

  def initialize
  end
end

class GbnfSpecTime < Llamero::BaseGrammar
  property at : Time = Time.unix(0)

  def initialize
  end
end

class GbnfSpecBadUnion < Llamero::BaseGrammar
  property value : Int32 | String = 0

  def initialize
  end
end

class GbnfSpecNumericUnion < Llamero::BaseGrammar
  property value : Int32 | Float64 = 0

  def initialize
  end
end

class GbnfSpecBadHash < Llamero::BaseGrammar
  property counts : Hash(Int32, String) = {} of Int32 => String

  def initialize
  end
end

class GbnfSpecDeepArray < Llamero::BaseGrammar
  property matrix : Array(Array(Array(Array(Array(String))))) = [] of Array(Array(Array(Array(String))))

  def initialize
  end
end

# Deliberately over budget: 7 optional fields (cap is 6).
class GbnfSpecTooManyOptionals < Llamero::BaseGrammar
  property a : String? = nil
  property b : String? = nil
  property c : String? = nil
  property d : String? = nil
  property e : String? = nil
  property f : String? = nil
  property g : String? = nil

  def initialize
  end
end

# At the cap: 6 optionals = 64 subset alternatives, still within budget.
class GbnfSpecSixOptionals < Llamero::BaseGrammar
  property a : String? = nil
  property b : String? = nil
  property c : String? = nil
  property d : String? = nil
  property e : String? = nil
  property f : String? = nil

  def initialize
  end
end

# Depth chain: 9 levels of nesting (cap is 8).
{% begin %}
  {% for i in (1..9) %}
    class GbnfSpecDepth{{ i }} < Llamero::BaseGrammar
      {% if i < 9 %}
        property child : GbnfSpecDepth{{ i + 1 }} = GbnfSpecDepth{{ i + 1 }}.new
      {% else %}
        property leaf : Int32 = 0
      {% end %}

      def initialize
      end
    end
  {% end %}
{% end %}

describe Llamero::GbnfBuilder do
  describe "golden grammar" do
    it "emits the exact grammar for a flat type" do
      expected = <<-'GBNF'
      root ::= test-person-grammar
      ws ::= [ \t\n\r]{0,20}
      string ::= "\"" char* "\""
      char ::= [^"\\\x00-\x1F] | "\\" (["\\/bfnrt] | "u" hex hex hex hex)
      hex ::= [0-9a-fA-F]
      int ::= "-"? ("0" | [1-9][0-9]*)
      test-person-grammar ::= "{" ws "\"name\"" ws ":" ws string ws "," ws "\"age\"" ws ":" ws int ws "}"
      GBNF
      TestPersonGrammar.to_gbnf.should eq(expected + "\n")
    end
  end

  describe "type matrix" do
    it "covers strings, ints, uints, floats, bools, enums, arrays, hashes, nested types and optionals" do
      grammar = GbnfSpecMatrix.to_gbnf

      grammar.should contain("root ::= gbnf-spec-matrix")
      grammar.should contain(%(int ::= "-"? ("0" | [1-9][0-9]*)))
      grammar.should contain(%(uint ::= "0" | [1-9][0-9]*))
      grammar.should contain(%(float ::= "-"? ("0" | [1-9][0-9]*) ("." [0-9]+)? ([eE] [+-]? [0-9]+)?))
      grammar.should contain(%(bool ::= "true" | "false"))
      grammar.should contain(%(null ::= "null"))
      grammar.should contain(%(gbnf-spec-priority ::= "\\"low\\"" | "\\"high\\"" | "\\"very_high\\""))
      grammar.should contain(%(string-arr ::= "[" ws (string (ws "," ws string)*)? ws "]"))
      grammar.should contain(%(int-map ::= "{" ws (string ws ":" ws int (ws "," ws string ws ":" ws int)*)? ws "}"))
      grammar.should contain(%(gbnf-spec-address ::= "{" ws "\\"city\\"" ws ":" ws string ws "," ws "\\"zip\\"" ws ":" ws string ws "}"))
      grammar.should contain(%(gbnf-spec-address-arr ::= "[" ws (gbnf-spec-address (ws "," ws gbnf-spec-address)*)? ws "]"))
      # optional field present-variant carries (string | null)
      grammar.should contain(%("\\"nickname\\"" ws ":" ws (string | null)))
    end

    it "keeps keys in declaration order and enumerates optional subsets (1 optional = 2 variants)" do
      grammar = GbnfSpecMatrix.to_gbnf
      rule = grammar.lines.find!(&.starts_with?("gbnf-spec-matrix ::="))
      rule.split(" | \"{\"").size.should eq(2) # two full object variants
      # declaration order within a variant
      name_idx = rule.index!(%("\\"name\\""))
      age_idx = rule.index!(%("\\"age\\""))
      friends_idx = rule.index!(%("\\"friends\\""))
      (name_idx < age_idx).should be_true
      (age_idx < friends_idx).should be_true
    end

    it "generates grammar whose sample output round-trips through T.from_json" do
      sample = {
        "name" => "Alice", "age" => 30, "count" => 2, "score" => 1.5,
        "active" => true, "priority" => "very_high", "tags" => ["x"],
        "lookup" => {"a" => 1}, "address" => {"city" => "Paris", "zip" => "75001"},
        "friends" => [{"city" => "Nice", "zip" => "06000"}],
      }.to_json
      parsed = GbnfSpecMatrix.from_json(sample)
      parsed.name.should eq("Alice")
      parsed.priority.should eq(GbnfSpecPriority::VeryHigh)
    end

    it "honors JSON::Field key renames and ignores ignored fields" do
      grammar = GbnfSpecRenamed.to_gbnf
      grammar.should contain(%("\\"fullName\\""))
      grammar.should_not contain("internal")
    end

    it "widens numeric unions" do
      grammar = GbnfSpecNumericUnion.to_gbnf
      grammar.should contain(%("\\"value\\"" ws ":" ws float))
    end

    it "allows exactly 6 optionals (64 subset alternatives)" do
      grammar = GbnfSpecSixOptionals.to_gbnf
      rule = grammar.lines.find!(&.starts_with?("gbnf-spec-six-optionals ::="))
      # one "{" opener per object variant; " | " also appears inside
      # (string | null) so it cannot be used to count variants
      rule.scan(/"\{"/).size.should eq(64)
      GbnfSpecSixOptionals.gbnf_within_budget?.should be_true
    end
  end

  describe "refusals (cliff policy)" do
    it "refuses direct recursion with a reason, without a compile error on the lenient path" do
      GbnfSpecRecursive.to_gbnf?.should be_nil
      GbnfSpecRecursive.gbnf_within_budget?.should be_false
      GbnfSpecRecursive.gbnf_fallback_reason.not_nil!.should contain("recursive type GbnfSpecRecursive")
    end

    it "refuses mutual recursion" do
      GbnfSpecMutualA.gbnf_fallback_reason.not_nil!.should contain("recursive type")
    end

    it "refuses more than 6 optional fields" do
      GbnfSpecTooManyOptionals.to_gbnf?.should be_nil
      GbnfSpecTooManyOptionals.gbnf_fallback_reason.not_nil!.should contain("7 optional fields")
    end

    it "refuses nesting deeper than 8" do
      GbnfSpecDepth1.gbnf_fallback_reason.not_nil!.should contain("nesting depth exceeds 8")
    end

    it "refuses types with no JSON-validity-preserving production (Time)" do
      GbnfSpecTime.gbnf_fallback_reason.not_nil!.should contain("unsupported type Time")
    end

    it "refuses non-allowlisted unions" do
      GbnfSpecBadUnion.gbnf_fallback_reason.not_nil!.should contain("not on the allowlist")
    end

    it "refuses non-String hash keys" do
      GbnfSpecBadHash.gbnf_fallback_reason.not_nil!.should contain("Hash keys")
    end

    it "refuses arrays nested deeper than 4" do
      GbnfSpecDeepArray.gbnf_fallback_reason.not_nil!.should contain("nesting at GbnfSpecDeepArray#matrix exceeds 4")
    end

    it "refuses custom JSON converters" do
      GbnfSpecConverter.gbnf_fallback_reason.not_nil!.should contain("converter")
    end

    it "keeps schema generation working for refused types (fallback path stays honest)" do
      # NOTE: recursive types are excluded here - JsonSchemaBuilder (pre-existing)
      # also cannot handle them (unbounded runtime recursion), so there is no
      # schema-prompt fallback for recursion either; both paths refuse.
      GbnfSpecTooManyOptionals.to_json_schema_string.should contain("properties")
      GbnfSpecTime.to_json_schema_string.should contain("date-time")
    end
  end

  describe "compile-time refusal surface" do
    it "fails compilation when to_gbnf is called on a refused type" do
      crystal = Process.find_executable("crystal")
      pending!("crystal compiler not on PATH") unless crystal

      fixture = File.join(Dir.current, "tmp", "gbnf_compile_refusal_#{Random::Secure.hex(4)}.cr")
      Dir.mkdir_p(File.dirname(fixture))
      File.write(fixture, <<-CR)
        require "../src/llamero"

        class CompileRefusalNode < Llamero::BaseGrammar
          property value : Int32 = 0
          property child : CompileRefusalNode? = nil
        end

        puts CompileRefusalNode.to_gbnf
        CR

      output = IO::Memory.new
      status = Process.run(crystal, ["build", "--no-codegen", fixture], output: output, error: output)
      status.success?.should be_false
      output.to_s.should contain("GBNF for CompileRefusalNode exceeds budget: recursive type CompileRefusalNode")
    ensure
      File.delete(fixture) if fixture && File.exists?(fixture)
    end
  end
end
