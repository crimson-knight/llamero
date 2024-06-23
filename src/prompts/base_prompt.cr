# Representing the collection of individual messages that compose an entire "prompt" series for interacting with an LLM.
# 
# It is recommended to use the `system_prompt` when initializing your prompt vs adding a system prompt message to the prompt chain.
# Doing this will allow you to re-use your prompt chain with different system prompts without having to re-initialize your prompt chain. This is very useful when using a MoE workflow.
class Llamero::BasePrompt
  # The system prompt that belongs to this collection of messages
  property system_prompt : String = ""

  # The collection of messages that make up this prompt, in order. Does not include the system prompt
  property prompt_chain : Array(PromptMessage) = [] of PromptMessage

  # The composed prompt chain in a format that can be used by LLM's, specifically chat-based models or instruction models
  property composed_prompt_chain_for_instruction_models : String = ""

  # Initialize your prompt chain with a system prompt, or an array of existing `PromptMessage` objects
  def initialize(system_prompt : String = "", messages : Array(PromptMessage) = [] of PromptMessage)
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
    prompt_string_as_its_being_built += "#{system_prompt_opening_tag}\n#{@system_prompt}\n#{system_prompt_closing_tag}\n\n" if !@system_prompt.empty?

    # Add the user prompt
    prompt_string_as_its_being_built += "#{user_prompt_opening_tag}\n#{@prompt_chain.map { |message| message.to_llm_instruction_prompt_syntax }.join("\n")}\n#{user_prompt_closing_tag}"

    # Add the unique token to split on and set the final string

    @composed_prompt_chain_for_instruction_models = prompt_string_as_its_being_built + unique_ending_token
  end
end
