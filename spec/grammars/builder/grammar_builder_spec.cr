require "../../spec_helper"

# Expected grammar output for this test class:
# ```gbnf
# root ::= TestGrammar
# TestGrammar ::= "{\"test_property\":"   String   ", \"test_property_2\":"   Int   ", \"test_property_3\":"   StringArray   ", \"test_property_4\":"   IntArray   ", \"test_property_5\":"   Float   ", \"test_property_6\":"   Bool   ", \"test_property_7\":"   IntOrNull   "}"
# String ::= "\""  ([^"]*)  "\""
# Int ::= "-?[0-9]+"
# Float ::= "-?[0-9]+\.[0-9]+"
# Bool ::= true | false
# Time ::= "\"   [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}Z   \""
# IntOrNull ::= "-?[0-9]+" | null
# BoolOrNull ::= true | false | null
# FloatOrNull ::= Float | null
# StringArray ::= "[]" | "["  String  (","   String)*?  "]"
# IntArray ::= "[]" | "["  Int(","   Int  )*? "]"
# FloatArray ::= "[]" | "["  Float(","   Float  )*? "]"
# BoolArray ::= "[]" | "["  Bool(","   Bool  )*? "]"
# TimeArray ::= "[]" | "["  Time(","   Time  )*? "]"
# ```
class TestGrammar < Llamero::BaseGrammar
  property test_property : String = "Test"
  property test_property_2 : Int32 = 1
  property test_property_3 : Array(String) = ["test"]
  property test_property_4 : Array(Int32) = [1, 2, 3]
  property test_property_5 : Float64 = 1.0
  property test_property_6 : Bool = true
  property test_property_7 : Int32? = nil
  property grammar3 : TestGrammar3 = TestGrammar3.from_json(%({}))
  property test_date_time_property : Time = Time.utc
  property test_object_property : TestGrammar2 = TestGrammar2.from_json(%({}))
  property test_object_array_property : Array(TestGrammar2) = [TestGrammar2.from_json(%({}))]
  property test_object_array_should_raise : Array(TestGrammar2) = [] of TestGrammar2
end

class TestGrammar2 < Llamero::BaseGrammar
  property test_grammar2_property : String = "Test2"
  property third_layer_nested_object : TestGrammar3 = TestGrammar3.from_json(%({}))
end

class TestGrammar3 < Llamero::BaseGrammar
  property deep_child_property : String = "Test3"
end

describe Llamero::Grammar::Builder::GrammarBuilder do
  it "can be used to build a grammar" do
    placeholder_grammar = TestGrammar.from_json(%({}))

    io = placeholder_grammar.to_grammar_file
    # puts io.rewind.gets_to_end
    # # Do something to test the actual grammar file output here.
    # This will need to wait until I have a fully working chart of what to expect for valid output
  end
end
