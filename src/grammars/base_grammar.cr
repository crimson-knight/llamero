require "json"
require "../schemas/json_schema_builder"

# Base class for structured responses from AI providers.
#
# Define properties on subclasses to create schemas for structured output.
# All properties will be automatically converted to JSON Schema format
# for use with API providers like OpenAI, Anthropic, Groq, etc.
#
# Any properties using non-primitive types must also inherit from `Llamero::BaseGrammar`.
#
# ```crystal
# class PersonInfo < Llamero::BaseGrammar
#   property name : String = ""
#   property age : Int32 = 0
# end
#
# # Use with API client
# response = client.chat_structured(messages, PersonInfo)
# person = response.parsed.not_nil!
# puts person.name
# ```
class Llamero::BaseGrammar
  include JSON::Serializable

  # Creates a JSON Schema representation of this grammar class.
  # Used for structured output with API providers like OpenAI, Anthropic, etc.
  #
  # ```crystal
  # class PersonInfo < Llamero::BaseGrammar
  #   property name : String = ""
  #   property age : Int32 = 0
  # end
  #
  # schema = PersonInfo.to_json_schema
  # # => {"$schema": "...", "type": "object", "properties": {...}}
  # ```
  def self.to_json_schema : Hash(String, JSON::Any)
    JsonSchemaBuilder(self).new(self).build
  end

  # Returns the JSON Schema as an IO object
  def self.to_json_schema_io : IO
    JsonSchemaBuilder(self).new(self).build_to_io
  end

  # Returns the JSON Schema as a JSON string
  def self.to_json_schema_string : String
    to_json_schema.to_json
  end
end
