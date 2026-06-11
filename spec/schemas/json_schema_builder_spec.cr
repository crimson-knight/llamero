require "../spec_helper"

describe Llamero::JsonSchemaBuilder do
  describe "#build" do
    it "generates schema for simple grammar with primitives" do
      schema = TestPersonGrammar.to_json_schema

      schema["type"]?.should eq(JSON::Any.new("object"))
      schema["additionalProperties"]?.should eq(JSON::Any.new(false))

      properties = schema["properties"]?.try(&.as_h)
      properties.should_not be_nil

      if props = properties
        props["name"]?.try(&.as_h).try(&.["type"]?).should eq(JSON::Any.new("string"))
        props["age"]?.try(&.as_h).try(&.["type"]?).should eq(JSON::Any.new("integer"))
      end
    end

    it "includes required properties" do
      schema = TestPersonGrammar.to_json_schema

      required = schema["required"]?.try(&.as_a.map(&.as_s))
      required.should_not be_nil

      if req = required
        req.should contain("name")
        req.should contain("age")
      end
    end

    it "generates schema with arrays" do
      schema = TestAnalysisGrammar.to_json_schema

      properties = schema["properties"]?.try(&.as_h)
      properties.should_not be_nil

      if props = properties
        tags_schema = props["tags"]?.try(&.as_h)
        tags_schema.should_not be_nil

        if ts = tags_schema
          ts["type"]?.should eq(JSON::Any.new("array"))
          items = ts["items"]?.try(&.as_h)
          items.try(&.["type"]?).should eq(JSON::Any.new("string"))
        end
      end
    end

    it "generates schema with float types" do
      schema = TestAnalysisGrammar.to_json_schema

      properties = schema["properties"]?.try(&.as_h)
      properties.should_not be_nil

      if props = properties
        score_schema = props["score"]?.try(&.as_h)
        score_schema.should_not be_nil

        if ss = score_schema
          ss["type"]?.should eq(JSON::Any.new("number"))
        end
      end
    end

    it "generates schema with nested objects" do
      schema = NestedGrammar.to_json_schema

      properties = schema["properties"]?.try(&.as_h)
      properties.should_not be_nil

      if props = properties
        person_schema = props["person"]?.try(&.as_h)
        person_schema.should_not be_nil
      end

      # Should have $defs for nested types
      defs = schema["$defs"]?.try(&.as_h)
      defs.should_not be_nil
    end

    it "includes schema version" do
      schema = TestPersonGrammar.to_json_schema
      schema_val = schema["$schema"]?.try(&.as_s)
      schema_val.should_not be_nil
      schema_val.not_nil!.should contain("json-schema.org")
    end
  end

  describe "#to_json_schema_string" do
    it "returns valid JSON string" do
      json_str = TestPersonGrammar.to_json_schema_string

      # Should be valid JSON
      parsed = JSON.parse(json_str)
      parsed["type"]?.should eq(JSON::Any.new("object"))
    end
  end
end
