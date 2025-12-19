require "json"

module Llamero
  # Builds JSON Schema from Crystal classes that inherit from BaseGrammar.
  # This enables structured output validation with API providers like OpenAI, Anthropic, etc.
  #
  # The builder uses compile-time macros to introspect class properties and generate
  # a corresponding JSON Schema that can be sent to API providers.
  #
  # Usage:
  # ```crystal
  # class PersonInfo < Llamero::BaseGrammar
  #   property name : String = ""
  #   property age : Int32 = 0
  #   property email : String? = nil
  # end
  #
  # schema = Llamero::JsonSchemaBuilder.new(PersonInfo).build
  # # => {"type": "object", "properties": {...}, "required": [...]}
  # ```
  class JsonSchemaBuilder(T)
    # The schema being built
    property schema : Hash(String, JSON::Any) = {} of String => JSON::Any

    # Definitions for nested objects (using $defs for JSON Schema draft-07+)
    property definitions : Hash(String, JSON::Any) = {} of String => JSON::Any

    def initialize(@klass : T.class)
    end

    # Build the JSON Schema for the class
    def build : Hash(String, JSON::Any)
      @schema["$schema"] = JSON::Any.new("http://json-schema.org/draft-07/schema#")
      @schema["title"] = JSON::Any.new(T.name.split("::").last)
      @schema["type"] = JSON::Any.new("object")

      properties = {} of String => JSON::Any
      required = [] of JSON::Any

      {% begin %}
        {% for ivar in T.instance_vars %}
          {% resolved_type = ivar.type.resolve %}
          {% is_nilable = resolved_type.nilable? %}
          {% non_nil_type = resolved_type.union_types.reject { |t| t == Nil }.first %}

          # Add to properties
          properties[{{ ivar.name.stringify }}] = build_type_schema(
            {{ non_nil_type }},
            {{ is_nilable }}
          )

          # Add to required array if not nilable
          {% unless is_nilable %}
            required << JSON::Any.new({{ ivar.name.stringify }})
          {% end %}
        {% end %}
      {% end %}

      @schema["properties"] = JSON::Any.new(properties)
      @schema["required"] = JSON::Any.new(required) unless required.empty?
      @schema["additionalProperties"] = JSON::Any.new(false)

      # Add definitions if any nested objects were encountered
      unless @definitions.empty?
        @schema["$defs"] = JSON::Any.new(@definitions)
      end

      @schema
    end

    # Build schema to IO for compatibility with grammar interface
    def build_to_io : IO
      io = IO::Memory.new
      io << build.to_json
      io.rewind
      io
    end

    # Convert schema to JSON string
    def to_json : String
      build.to_json
    end

    # Build schema for a specific type
    private macro build_type_schema(type, is_nilable)
      {% if type <= String %}
        build_string_schema({{ is_nilable }})
      {% elsif type <= Int8 || type <= Int16 || type <= Int32 || type <= Int64 || type <= UInt8 || type <= UInt16 || type <= UInt32 || type <= UInt64 %}
        build_integer_schema({{ is_nilable }})
      {% elsif type <= Float32 || type <= Float64 %}
        build_number_schema({{ is_nilable }})
      {% elsif type <= Bool %}
        build_boolean_schema({{ is_nilable }})
      {% elsif type <= Time %}
        build_datetime_schema({{ is_nilable }})
      {% elsif type <= Array %}
        build_array_schema({{ type }}, {{ is_nilable }})
      {% elsif type <= Llamero::BaseGrammar %}
        build_object_ref_schema({{ type }}, {{ is_nilable }})
      {% else %}
        # Fallback for unknown types - treat as string
        build_string_schema({{ is_nilable }})
      {% end %}
    end

    private def build_string_schema(is_nilable : Bool) : JSON::Any
      if is_nilable
        JSON::Any.new({"type" => JSON::Any.new(["string", "null"].map { |t| JSON::Any.new(t) })})
      else
        JSON::Any.new({"type" => JSON::Any.new("string")})
      end
    end

    private def build_integer_schema(is_nilable : Bool) : JSON::Any
      if is_nilable
        JSON::Any.new({"type" => JSON::Any.new(["integer", "null"].map { |t| JSON::Any.new(t) })})
      else
        JSON::Any.new({"type" => JSON::Any.new("integer")})
      end
    end

    private def build_number_schema(is_nilable : Bool) : JSON::Any
      if is_nilable
        JSON::Any.new({"type" => JSON::Any.new(["number", "null"].map { |t| JSON::Any.new(t) })})
      else
        JSON::Any.new({"type" => JSON::Any.new("number")})
      end
    end

    private def build_boolean_schema(is_nilable : Bool) : JSON::Any
      if is_nilable
        JSON::Any.new({"type" => JSON::Any.new(["boolean", "null"].map { |t| JSON::Any.new(t) })})
      else
        JSON::Any.new({"type" => JSON::Any.new("boolean")})
      end
    end

    private def build_datetime_schema(is_nilable : Bool) : JSON::Any
      schema = {"type" => JSON::Any.new("string"), "format" => JSON::Any.new("date-time")}
      if is_nilable
        schema["type"] = JSON::Any.new(["string", "null"].map { |t| JSON::Any.new(t) })
      end
      JSON::Any.new(schema)
    end

    private macro build_array_schema(array_type, is_nilable)
      {% item_types = array_type.type_vars %}
      {% if item_types.size > 0 %}
        {% item_type = item_types.first %}
        items_schema = build_type_schema({{ item_type }}, false)
        schema = {
          "type" => JSON::Any.new("array"),
          "items" => items_schema
        }
        {% if is_nilable %}
          # For nilable arrays, wrap in anyOf
          JSON::Any.new({
            "anyOf" => JSON::Any.new([
              JSON::Any.new(schema),
              JSON::Any.new({"type" => JSON::Any.new("null")})
            ])
          })
        {% else %}
          JSON::Any.new(schema)
        {% end %}
      {% else %}
        # Array without type parameter - use any items
        JSON::Any.new({"type" => JSON::Any.new("array")})
      {% end %}
    end

    private macro build_object_ref_schema(object_type, is_nilable)
      # Add the object definition if not already present
      def_name = {{ object_type.stringify.split("::").last }}

      unless @definitions.has_key?(def_name)
        # Build nested object schema
        nested_builder = JsonSchemaBuilder({{ object_type }}).new({{ object_type }})
        nested_schema = nested_builder.build

        # Remove $schema from nested definitions
        nested_schema.delete("$schema")

        @definitions[def_name] = JSON::Any.new(nested_schema)

        # Merge any nested definitions
        nested_builder.definitions.each do |k, v|
          @definitions[k] = v unless @definitions.has_key?(k)
        end
      end

      ref_schema = {"$ref" => JSON::Any.new("#/$defs/#{def_name}")}

      {% if is_nilable %}
        JSON::Any.new({
          "anyOf" => JSON::Any.new([
            JSON::Any.new(ref_schema),
            JSON::Any.new({"type" => JSON::Any.new("null")})
          ])
        })
      {% else %}
        JSON::Any.new(ref_schema)
      {% end %}
    end
  end
end
