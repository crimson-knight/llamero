require "./retry_config"

module Llamero
  # Supported provider identifiers
  enum Provider
    OpenAI
    Anthropic
    Groq
    OpenRouter

    def to_sym : Symbol
      case self
      when .open_ai?     then :openai
      when .anthropic?   then :anthropic
      when .groq?        then :groq
      when .open_router? then :openrouter
      else                    :unknown
      end
    end

    def self.from_sym(sym : Symbol) : Provider
      case sym
      when :openai     then OpenAI
      when :anthropic  then Anthropic
      when :groq       then Groq
      when :openrouter then OpenRouter
      else
        raise APIError.new("Unknown provider: #{sym}")
      end
    end
  end

  # Configuration for a single provider in the client
  #
  # ```crystal
  # config = ProviderConfig.new(
  #   provider: :openai,
  #   default_model: "gpt-4o",
  #   retry_config: RetryConfig.aggressive
  # )
  # ```
  class ProviderConfig
    property provider : Symbol
    property default_model : String?
    property enabled : Bool
    property retry_config : RetryConfig

    # Cached client instance (lazy initialization)
    @client : APIClient?

    def initialize(
      @provider : Symbol,
      @default_model : String? = nil,
      @enabled : Bool = true,
      @retry_config : RetryConfig = RetryConfig.new
    )
      @client = nil
    end

    # Get or create the API client for this provider
    def client : APIClient
      @client ||= create_client
    end

    # Check if this provider is configured (has API key)
    def configured? : Bool
      ConfigLoader.instance.provider_configured?(@provider.to_s)
    end

    # Check if provider supports a specific feature
    def supports?(feature : Feature) : Bool
      client.supports?(feature)
    end

    private def create_client : APIClient
      case @provider
      when :openai
        OpenAIClient.new(default_model: @default_model)
      when :anthropic
        AnthropicClient.new(default_model: @default_model)
      when :groq
        GroqClient.new(default_model: @default_model)
      when :openrouter
        OpenRouterClient.new(default_model: @default_model)
      else
        raise APIError.new("Unknown provider: #{@provider}")
      end
    end
  end
end
