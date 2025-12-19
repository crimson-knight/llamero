# This class is the base class for all prompt templates.
# It is used to create a prompt template for creating a LoRA filter for a model.
class Llamero::BasePromptMessageTemplate

  # Create a list of properties that define the variables to be generated and used in the prompt template
  def initialize(@system_prompt)

    @system_prompt = system_prompt
    @prompt_chain = messages
  end
end
