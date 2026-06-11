require "../spec_helper"

describe Llamero::BaseGrammar do
  describe ".to_json_schema" do
    it "generates a JSON schema hash" do
      schema = TestPersonGrammar.to_json_schema

      schema.should be_a(Hash(String, JSON::Any))
      schema["type"]?.should eq(JSON::Any.new("object"))
    end

    it "includes all properties" do
      schema = TestPersonGrammar.to_json_schema
      properties = schema["properties"]?.try(&.as_h)

      properties.should_not be_nil
      if props = properties
        props.has_key?("name").should be_true
        props.has_key?("age").should be_true
      end
    end
  end

  describe ".to_json_schema_string" do
    it "returns JSON string representation" do
      json_str = TestPersonGrammar.to_json_schema_string

      json_str.should be_a(String)
      json_str.should contain("\"type\"")
      json_str.should contain("\"object\"")
    end

    it "is valid JSON" do
      json_str = TestPersonGrammar.to_json_schema_string
      parsed = JSON.parse(json_str)

      parsed.should_not be_nil
    end
  end

  describe "JSON serialization" do
    it "serializes to JSON" do
      grammar = TestPersonGrammar.new
      grammar.name = "John"
      grammar.age = 30

      json = grammar.to_json
      json.should contain("\"name\":\"John\"")
      json.should contain("\"age\":30")
    end

    it "deserializes from JSON" do
      json = %q({"name":"Jane","age":25})
      grammar = TestPersonGrammar.from_json(json)

      grammar.name.should eq("Jane")
      grammar.age.should eq(25)
    end
  end

  describe "with nested grammars" do
    it "generates schema with $defs for nested types" do
      schema = NestedGrammar.to_json_schema

      defs = schema["$defs"]?.try(&.as_h)
      defs.should_not be_nil
    end

    it "serializes nested structures" do
      grammar = NestedGrammar.new
      grammar.title = "Test"
      grammar.person.name = "Alice"
      grammar.person.age = 28

      json = grammar.to_json
      json.should contain("\"title\":\"Test\"")
      json.should contain("\"name\":\"Alice\"")
    end

    it "deserializes nested structures" do
      json = %q({"title":"Hello","person":{"name":"Bob","age":35}})
      grammar = NestedGrammar.from_json(json)

      grammar.title.should eq("Hello")
      grammar.person.name.should eq("Bob")
      grammar.person.age.should eq(35)
    end
  end

  describe "with arrays" do
    it "handles array properties" do
      grammar = TestAnalysisGrammar.new
      grammar.sentiment = "positive"
      grammar.score = 0.95_f32
      grammar.tags = ["happy", "excited"]

      json = grammar.to_json
      parsed = JSON.parse(json)

      parsed["tags"].as_a.map(&.as_s).should eq(["happy", "excited"])
    end
  end
end
