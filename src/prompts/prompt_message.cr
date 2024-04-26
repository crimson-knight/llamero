# A small helper class that holds the role and content of a message in a prompt series.
class Llamero::PromptMessage
  property role : String = ""
  property content : String = ""

  def initialize(role : String, content : String)
    @role = role
    @content = content
  end

  def to_llm_instruction_prompt_syntax : String
    "#{@role}:\n#{@content}"
  end
end
