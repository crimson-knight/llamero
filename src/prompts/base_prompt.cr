# Representing the collection of individual messages that compose an entire "prompt" series for interacting with an LLM.
class Llamero::BasePrompt
  # The system prompt that belongs to this collection of messages
  property system_prompt : String = ""

  # The collection of messages that make up this prompt, in order. Does not include the system prompt
  property prompt_chain : Array(PromptMessage) = [] of PromptMessage

  # The composed prompt chain in a format that can be used by LLM's, specifically chat-based models or instruction models
  property composed_prompt_chain_for_instruction_models : String = ""

  def initialize(system_prompt : String = "", messages : Array[PromptMessage] = [] of PromptMessage)
    @system_prompt = system_prompt
    @prompt_chain = messages
  end

  def add_message(role : String, content : String)
    @prompt_chain << PromptMessage.new(role, content)
  end

  # Creates the prompt chain for the specific model parameters that are passed in.
  #
  # This is intentionally decoupled from the model itself because it allows you to use the same prompt across multiple models, adjusting the wrappers as necessary
  def to_llm_instruction_prompt_structure(system_prompt_opening_tag : String, system_prompt_closing_tag : String, user_prompt_opening_tag : String, user_prompt_closing_tag : String, unique_ending_token : String)
    prompt_string_as_its_being_built = ""

    # Add the system prompt if a system prompt is provided
    prompt_string_as_its_being_built << "#{system_prompt_opening_tag}\n#{@system_prompt}\n#{system_prompt_closing_tag}\n\n" if !@system_prompt.empty?

    # Add the user prompt
    prompt_string_as_its_being_built << "#{user_prompt_opening_tag}\n#{@prompt_chain.map { |message| message.to_llm_instruction_prompt_syntax }.join("\n")}\n#{user_prompt_closing_tag}"

    @composed_prompt_chain_for_instruction_models = prompt_string_as_its_being_built
  end
end
