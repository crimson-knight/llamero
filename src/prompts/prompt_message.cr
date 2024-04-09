# A small helper class that holds the role and content of a message in a prompt series.
class Llamero::PromptMessage
  property role : String = ""
  property content : String = ""

  def initialize(role : String, content : String) : self
    @role = role
    @content = content
  end
end
