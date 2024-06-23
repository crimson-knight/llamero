require "json"

# A base class for grammars. Grammars are the expected responses syntax from the LLM. Using a grammar can significantly help improve the consistency of the structured responses while saving on context window tokens.
# 
# To create a grammar, inherit from this class and define properties on the child class. All properties will be automatically converted to a grammar syntax.
# Any properties that use a non-primitive type must inherit from `Llamero::BaseGrammar` as well.
#
# This class defines the necessary methods for rendering a JSON serializable object into a grammar syntax that can be provided to the LLM at run-time or output to a file.
class Llamero::BaseGrammar
  include JSON::Serializable

  # Creates the grammar in a format that can be saved into a `.gbnf` file
  def to_grammar_file(is_root_object : Bool = true) : IO
    Grammar::Builder::GrammarBuilder.new(self).create_grammar_output(is_root_object: is_root_object)
  end

  def self.get_grammar_output_for_object : IO
    Grammar::Builder::GrammarBuilder.new(self.from_json(%({}))).create_grammar_output(is_root_object: false)
  end

  # This method is intended to be used to update the grammar from a JSON string or IO object vs creating an entirely new object, this way you can re-use the same grammar on multiple models and have the grammar update with each new models input.
  # def update_from_json(json_string_or_io)
  #   raise "This method needs to be overridden by a subclass."
  # end
end

# Improvement notes that aren't intended to be documented outside of the code base:
#
# 1. Improve this to add annotations that would allow setting the amount of tokens to predict for a specific attribute.
#   This would let the developer adjust how large of a reply they would need in total which means more accurate generation.
#
#   How this would work:
#     - Create the annotation and have it take a value that represents the number of tokens the _value_ can be up to.
#     - This number, plus a cushion could then be calculated and used to dynamically manage the n_predict attribute. Making performance more efficient and a feature.
#
