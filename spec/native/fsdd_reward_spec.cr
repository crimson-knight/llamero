require "../spec_helper"

private CONTROLLER = <<-CR
class UsersController < Amber::Controller::Base
  def index : String
    "ok"
  end
end
CR

private HONEST_STUB = <<-CR
class UsersController < Amber::Controller::Base
  # Return the list of users for the index page.
  def index : Array(User)
    # TODO: load and return the users
  end
end
CR

private FABRICATED = <<-CR
class FabricatedController < FakeBase::Thing
  def index : String
    FakeApi.call
  end
end
CR

private PHP = <<-CR
public function index() {
  $user = current_user();
  return $user;
}
CR

private SYNTAX_ERR = "def foo(\n  bar\n"

module Llamero::Native
  describe FSDD do
    describe ".foreign?" do
      it "flags other-language code" do
        FSDD.foreign?(PHP).should be_true
        FSDD.foreign?("console.log(x)").should be_true
        FSDD.foreign?("const x = 1").should be_true
        FSDD.foreign?("attr_accessor :name").should be_true
        FSDD.foreign?("def __init__(self):\n  pass").should be_true
      end

      it "does not flag valid Crystal/Amber" do
        FSDD.foreign?(CONTROLLER).should be_false
        FSDD.foreign?(HONEST_STUB).should be_false
        FSDD.foreign?(%(record Point, x : Int32, y : Int32)).should be_false
        # Crystal regex globals and hash rockets are not "foreign".
        FSDD.foreign?(%(m = "a" =~ /(\\w)/\nputs $1)).should be_false
        FSDD.foreign?(%({"a" => 1, "b" => 2})).should be_false
      end
    end

    describe ".parses?" do
      it "accepts valid Crystal (even unformatted)" do
        FSDD.parses?(CONTROLLER).should be_true
        # valid but unformatted (cramped operator, unindented body)
        FSDD.parses?("def foo(x : Int32) : Int32\nx+1\nend").should be_true
      end

      it "rejects a syntax error" do
        FSDD.parses?(SYNTAX_ERR).should be_false
      end
    end

    describe ".honest_stub? / .admits_gap?" do
      it "recognizes a typed signature with a comment-only body" do
        FSDD.honest_stub?(HONEST_STUB).should be_true
        FSDD.admits_gap?(HONEST_STUB).should be_true
      end

      it "recognizes the FSDD 'business logic goes here' stub" do
        stub = "private def lock_accounts : Nil\n  # Your business logic goes here\nend"
        FSDD.honest_stub?(stub).should be_true
      end

      it "does not treat a fully-implemented method as a stub" do
        FSDD.honest_stub?(CONTROLLER).should be_false
        FSDD.admits_gap?(CONTROLLER).should be_false
      end
    end

    describe ".typed_method_fraction" do
      it "is 1.0 when every def has a return type" do
        FSDD.typed_method_fraction("def a : Int32\n  1\nend").should eq(1.0)
      end

      it "drops when a def lacks a return type" do
        code = "def a : Int32\n  1\nend\ndef b\n  2\nend"
        FSDD.typed_method_fraction(code).should eq(0.5)
      end
    end

    describe ".naming_score" do
      it "penalizes puts and rewards conventions" do
        FSDD.naming_score("def go : Nil\n  puts \"x\"\nend").should be < 1.0
        FSDD.naming_score(CONTROLLER).should eq(1.0)
      end

      it "penalizes an unprefixed Array property and a bare boolean" do
        bad = "property orders : Array(Order)\nproperty active : Bool"
        good = "property list_of_orders : Array(Order)\nproperty is_active : Bool"
        FSDD.naming_score(bad).should be < FSDD.naming_score(good)
      end

      it "penalizes hand-rolled JSON over JSON::Serializable" do
        FSDD.hand_rolled_json?("data = JSON.parse(body)").should be_true
        FSDD.hand_rolled_json?("include JSON::Serializable\nx = y.to_json").should be_false
      end
    end
  end

  describe FSDDReward do
    # everything grounded except Fake*/Fabricated* constants
    grounding = ->(s : String) { !s.includes?("Fake") && !s.includes?("Fabricated") }
    symbols = ->(code : String) { code.scan(/\b([A-Z][A-Za-z0-9_]*)\b/).map(&.[1]).uniq }

    it "orders the grading ladder: foreign < syntax < fabricated < valid <= honest < compiling" do
      r = FSDDReward.new(grounding: grounding, symbols: symbols)
      rc = FSDDReward.new(grounding: grounding, symbols: symbols, compiles: ->(_c : String) { true })

      s_foreign    = r.score("", PHP)
      s_syntax     = r.score("", SYNTAX_ERR)
      s_fabricated = r.score("", FABRICATED)
      s_valid      = r.score("", CONTROLLER)
      s_honest     = r.score("", HONEST_STUB)
      s_compiling  = rc.score("", CONTROLLER)

      s_foreign.should eq(0.0)
      (s_foreign < s_syntax).should be_true
      (s_syntax < s_fabricated).should be_true
      (s_fabricated < s_valid).should be_true
      # the anti-lying invariant: admitting a gap beats fabricating a body
      (s_fabricated < s_honest).should be_true
      (s_valid <= s_honest).should be_true
      (s_honest < s_compiling).should be_true
    end

    it "works as a deterministic core with no grounding/compile judge" do
      r = FSDDReward.new
      (r.score("", PHP) < r.score("", HONEST_STUB)).should be_true
      r.score("", SYNTAX_ERR).should eq(0.1)
    end

    it "is usable inside a Rubric" do
      rubric = Llamero::Native::Rubric.new(FSDDReward.new)
      total, breakdown = rubric.score("", HONEST_STUB)
      breakdown.has_key?("fsdd-honesty").should be_true
      (total > 0.5).should be_true
    end
  end
end
