require "./api_errors"
require "./retry_config"
require "./provider_config"
require "./model_mapping"
require "./base_api_client"
require "./openai_client"
require "./anthropic_client"
require "./groq_client"
require "./openrouter_client"

module Llamero
  # Primary client interface for interacting with AI providers.
  #
  # This is an abstract base class that users inherit from to create their
  # application's AI client. Provider configuration happens once in the
  # initializer - users never specify providers when calling `chat()`.
  #
  # ## Basic Usage
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
  # # Use it - no provider specification needed
  # client = MyAIClient.new
  # response = client.chat([Message.user("Hello!")])
  # puts response.content
  # puts "Provider used: #{response.provider_used}"
  # ```
  #
  # ## Structured Output
  #
  # ```crystal
  # class PersonInfo < Llamero::BaseGrammar
  #   property name : String = ""
  #   property age : Int32 = 0
  # end
  #
  # response = client.chat_structured(
  #   [Message.user("Give me a random person")],
  #   PersonInfo
  # )
  # puts response.parsed.not_nil!.name
  # ```
  #
  # ## Monitoring Failovers
  #
  # ```crystal
  # class MyAIClient < Llamero::Client
  #   def initialize
  #     super(primary: :openai, fallbacks: [:anthropic])
  #
  #     on_fallback do |from, to, error|
  #       Log.warn { "Failing over from #{from} to #{to}: #{error.message}" }
  #     end
  #
  #     on_retry do |provider, attempt, error|
  #       Log.info { "Retry #{attempt} for #{provider}: #{error.message}" }
  #     end
  #   end
  # end
  # ```
  abstract class Client
    # Provider configurations in order of preference
    getter providers : Array(ProviderConfig)

    # Global retry configuration
    getter retry_config : RetryConfig

    # Whether to automatically map models when falling back
    property auto_map_models : Bool

    # Callback for when failover occurs
    @on_fallback_callback : Proc(Symbol, Symbol, APIError, Nil)?

    # Callback for when retry occurs
    @on_retry_callback : Proc(Symbol, Int32, APIError, Nil)?

    def initialize(
      primary : Symbol,
      fallbacks : Array(Symbol) = [] of Symbol,
      @retry_config : RetryConfig = RetryConfig.new,
      @auto_map_models : Bool = true
    )
      @providers = build_provider_list(primary, fallbacks)
      @on_fallback_callback = nil
      @on_retry_callback = nil

      validate_providers!
    end

    # Register a callback for failover events
    def on_fallback(&block : Symbol, Symbol, APIError -> Nil)
      @on_fallback_callback = block
    end

    # Register a callback for retry events
    def on_retry(&block : Symbol, Int32, APIError -> Nil)
      @on_retry_callback = block
    end

    # Standard chat completion with automatic failover
    #
    # ```crystal
    # response = client.chat([Message.user("Hello!")])
    # puts response.content
    # puts response.provider_used  # :openai, :anthropic, etc.
    # ```
    def chat(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil
    ) : ChatResponse(Nil)
      execute_with_failover(nil) do |client, provider, mapped_model|
        client.chat(messages, mapped_model || model, temperature, max_tokens)
      end
    end

    # Structured output chat with automatic failover
    # Only uses providers that support structured output.
    #
    # ```crystal
    # response = client.chat_structured(
    #   [Message.user("Random person info")],
    #   PersonInfo
    # )
    # puts response.parsed.not_nil!.name
    # ```
    def chat_structured(
      messages : Array(Message),
      response_schema : T.class,
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil
    ) : ChatResponse(T) forall T
      execute_with_failover([Feature::StructuredOutput]) do |client, provider, mapped_model|
        client.chat_structured(messages, T, mapped_model || model, temperature, max_tokens)
      end
    end

    # Streaming chat completion with automatic failover
    # Only uses providers that support streaming.
    #
    # ```crystal
    # client.chat_stream([Message.user("Tell me a story")]) do |chunk|
    #   print chunk
    # end
    # ```
    def chat_stream(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
      &block : String -> Nil
    ) : Nil
      execute_with_failover([Feature::Streaming]) do |api_client, provider, mapped_model|
        api_client.chat_stream(messages, mapped_model || model, temperature, max_tokens, &block)
        # Return a dummy response since streaming doesn't return content
        ChatResponse(Nil).new(
          content: "",
          model: mapped_model || model || api_client.default_model
        )
      end
      nil
    end

    # Get list of available providers (configured and enabled)
    def available_providers : Array(Symbol)
      @providers.select(&.enabled).select(&.configured?).map(&.provider)
    end

    # Get list of providers that support specific features
    def providers_for_features(features : Array(Feature)) : Array(Symbol)
      filter_providers(features).map(&.provider)
    end

    # Check if any provider supports the given features
    def supports_features?(features : Array(Feature)) : Bool
      filter_providers(features).any?
    end

    private def build_provider_list(primary : Symbol, fallbacks : Array(Symbol)) : Array(ProviderConfig)
      all_providers = [primary] + fallbacks

      all_providers.compact_map do |provider_sym|
        config = ProviderConfig.new(provider_sym, retry_config: @retry_config)
        config if config.configured?
      end
    end

    private def validate_providers!
      if @providers.empty?
        raise APIError.new(
          "No providers configured. Please set API keys via environment variables " \
          "(OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.) or in the project config file"
        )
      end
    end

    private def filter_providers(require_features : Array(Feature)?) : Array(ProviderConfig)
      available = @providers.select(&.enabled).select(&.configured?)
      return available if require_features.nil? || require_features.empty?

      available.select do |provider_config|
        require_features.all? { |feature| provider_config.supports?(feature) }
      end
    end

    private def execute_with_failover(
      require_features : Array(Feature)?,
      &block : (APIClient, Symbol, String?) -> ChatResponse(T)
    ) : ChatResponse(T) forall T
      available = filter_providers(require_features)

      if available.empty?
        feature_list = require_features.try(&.map(&.to_s).join(", ")) || "none"
        raise APIError.new("No providers available with required features: #{feature_list}")
      end

      failed_attempts = [] of FailedAttempt
      start_time = Time.utc
      total_attempts = 0
      original_model : String? = nil

      available.each_with_index do |provider_config, provider_index|
        api_client = provider_config.client
        provider = provider_config.provider
        retry_config = provider_config.retry_config

        # Map model if auto-mapping enabled and not first provider
        mapped_model : String? = nil
        if @auto_map_models && provider_index > 0 && original_model
          original_provider = available.first.provider
          mapped_model = ModelMapping.find_equivalent(original_model, original_provider, provider)
        end

        (0..retry_config.max_retries).each do |retry_attempt|
          total_attempts += 1

          begin
            response = block.call(api_client, provider, mapped_model)

            # Store the model for potential mapping on retry
            original_model ||= response.model

            # Add metadata to response
            return add_response_metadata(
              response,
              provider,
              total_attempts,
              failed_attempts,
              Time.utc - start_time
            )
          rescue ex : RateLimitError
            if retry_config.should_retry?(ex, retry_attempt)
              delay = retry_config.delay_for_error(ex, retry_attempt)
              @on_retry_callback.try(&.call(provider, retry_attempt, ex))
              sleep(delay)
            else
              failed_attempts << FailedAttempt.new(provider, ex, retry_count: retry_attempt)
              notify_fallback(provider, available[provider_index + 1]?.try(&.provider), ex)
              break
            end
          rescue ex : ServerError
            if retry_config.should_retry?(ex, retry_attempt)
              delay = retry_config.delay_for_error(ex, retry_attempt)
              @on_retry_callback.try(&.call(provider, retry_attempt, ex))
              sleep(delay)
            else
              failed_attempts << FailedAttempt.new(provider, ex, retry_count: retry_attempt)
              notify_fallback(provider, available[provider_index + 1]?.try(&.provider), ex)
              break
            end
          rescue ex : AuthenticationError | QuotaExceededError
            # Never retry auth/billing errors, move to next provider
            failed_attempts << FailedAttempt.new(provider, ex)
            notify_fallback(provider, available[provider_index + 1]?.try(&.provider), ex)
            break
          rescue ex : APIError
            if ex.retryable && retry_config.should_retry?(ex, retry_attempt)
              delay = retry_config.delay_for_error(ex, retry_attempt)
              @on_retry_callback.try(&.call(provider, retry_attempt, ex))
              sleep(delay)
            else
              failed_attempts << FailedAttempt.new(provider, ex, retry_count: retry_attempt)
              notify_fallback(provider, available[provider_index + 1]?.try(&.provider), ex)
              break
            end
          end
        end
      end

      # All providers failed
      last_error = failed_attempts.last?.try(&.error) || APIError.new("All providers failed")
      raise APIError.new(
        "All #{available.size} providers failed. Last error: #{last_error.message}",
        status_code: last_error.status_code,
        response_body: last_error.response_body
      )
    end

    private def notify_fallback(from : Symbol, to : Symbol?, error : APIError)
      return unless to
      @on_fallback_callback.try(&.call(from, to, error))
    end

    private def add_response_metadata(
      response : ChatResponse(T),
      provider : Symbol,
      attempts : Int32,
      failed_attempts : Array(FailedAttempt),
      duration : Time::Span
    ) : ChatResponse(T) forall T
      # Create a new response with metadata
      # Note: We extend ChatResponse to include metadata properties
      ChatResponse(T).new(
        content: response.content,
        model: response.model,
        usage: response.usage,
        finish_reason: response.finish_reason,
        parsed: response.parsed,
        provider_used: provider,
        attempts: attempts
      )
    end
  end
end
