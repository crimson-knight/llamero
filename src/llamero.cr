require "./prompts/**"
require "./grammars/**"
require "./schemas/**"
require "./config/**"
require "./clients/**"
require "./clients/cli/**"
require "./native/**"

# Llamero - A Crystal library for interacting with AI/LLM providers
#
# Supports multiple providers with automatic failover:
# - OpenAI (GPT-4o, etc.)
# - Anthropic (Claude)
# - Groq (ultra-fast inference)
# - OpenRouter (400+ models)
#
# ## Recommended Usage: Unified Client with Failover
#
# ```crystal
# # Define your application's AI client
# class MyAIClient < Llamero::Client
#   def initialize
#     super(
#       primary: :openai,
#       fallbacks: [:anthropic, :groq]
#     )
#   end
# end
#
# # Use it - automatic failover, no provider specification needed
# client = MyAIClient.new
# response = client.chat([Llamero::Message.user("Hello!")])
# puts response.content
# puts "Provider used: #{response.provider_used}"
#
# # Structured output
# class PersonInfo < Llamero::BaseGrammar
#   property name : String = ""
#   property age : Int32 = 0
# end
#
# response = client.chat_structured(
#   [Llamero::Message.user("Give me a random person")],
#   PersonInfo
# )
# puts response.parsed.not_nil!.name
# ```
#
# ## Direct Provider Access (Advanced)
#
# You can also use individual provider clients directly:
#
# ```crystal
# client = Llamero::OpenAIClient.new
# response = client.chat([Llamero::Message.user("Hello!")])
# ```
module Llamero
  VERSION = "1.0.0"
end
