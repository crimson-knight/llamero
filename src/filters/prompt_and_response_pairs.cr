# Helper class that holds the prompt message template and the expected structured response
class Llamero::PromptAndResponsePairs
  property prompt_message_template : Llamero::BasePromptMessageTemplate
  property expected_structured_response : Llamero::BaseStructuredResponse

  def initialize(@prompt_message_template, @expected_structured_response)
  end
end

