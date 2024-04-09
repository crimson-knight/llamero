require "json"

# A base class for grammars. Grammars are the expected responses syntax from the LLM. Using a grammar can significantly help improve the consistency of the structured responses while saving on context window tokens.
#
# This class defines the necessary methods for rendering a JSON serializable object into a grammar syntax that can be provided to the LLM at run-time or output to a file.
class Llamero::BaseGrammer
  include JSON::Serializable

  # Creates the grammar in a format that can be saved into a `.gbnf` file
  def to_grammar_syntax
    # Returns the grammar syntax as a string.
    raise NotImplementedError, "You must implement the to_grammar_syntax method"
  end

  # Returns the grammar syntax as a string that's safe for use in the CLI to use at the time of execution
  def to_cli_grammar_syntax
    # Returns the grammar syntax as a string.
  end

  # Updates the target file from a JSON string or io object.
  def update_from_json(json_string_or_io)
    # Does nothing, TBD when it will be implemented
  end
end
