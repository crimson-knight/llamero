require "http/client"
require "json"
require "../config/config_loader"
require "../grammars/base_grammar"
require "./api_errors"

module Llamero
  # Enumeration of features that API providers may or may not support
  enum Feature
    StructuredOutput  # JSON Schema-based structured responses
    ToolCalling       # Function/tool calling capability
    Streaming         # Server-sent events streaming
    Embeddings        # Text embedding generation
    Vision            # Image understanding
  end

  # Role of a message in a conversation
  enum MessageRole
    System
    User
    Assistant
    Tool
  end

  # A single message in a conversation
  struct Message
    include JSON::Serializable

    property role : MessageRole
    property content : String
    property name : String?           # For tool results, the function name
    property tool_call_id : String?   # For tool results, reference to the tool call

    def initialize(@role : MessageRole, @content : String, @name : String? = nil, @tool_call_id : String? = nil)
    end

    # Convenience constructors
    def self.system(content : String) : Message
      new(MessageRole::System, content)
    end

    def self.user(content : String) : Message
      new(MessageRole::User, content)
    end

    def self.assistant(content : String) : Message
      new(MessageRole::Assistant, content)
    end

    def self.tool(content : String, tool_call_id : String, name : String? = nil) : Message
      new(MessageRole::Tool, content, name, tool_call_id)
    end
  end

  # Token usage statistics from an API call.
  # Cache fields are populated when the provider reports prompt-cache activity
  # (Anthropic today; others return zero).
  struct Usage
    include JSON::Serializable

    property input_tokens : Int32
    property output_tokens : Int32
    property cache_creation_input_tokens : Int32
    property cache_read_input_tokens : Int32

    def initialize(
      @input_tokens : Int32 = 0,
      @output_tokens : Int32 = 0,
      @cache_creation_input_tokens : Int32 = 0,
      @cache_read_input_tokens : Int32 = 0
    )
    end

    def total_tokens : Int32
      @input_tokens + @output_tokens
    end
  end

  # Response from a chat completion request
  # Includes optional metadata for failover tracking
  class ChatResponse(T)
    property content : String
    property model : String
    property usage : Usage
    property finish_reason : String
    property parsed : T?

    # Metadata for failover tracking (populated by Client)
    property provider_used : Symbol
    property attempts : Int32

    def initialize(
      @content : String,
      @model : String,
      @usage : Usage = Usage.new,
      @finish_reason : String = "stop",
      @parsed : T? = nil,
      @provider_used : Symbol = :unknown,
      @attempts : Int32 = 1
    )
    end
  end

  # Note: APIError and related error classes are defined in api_errors.cr

  # Base class for all API clients
  # Provides common interface for interacting with LLM providers
  abstract class APIClient
    # Default configuration from config loader
    protected getter config : ConfigLoader

    # Provider-specific settings
    getter api_key : String
    getter base_url : String
    getter default_model : String
    getter timeout : Time::Span

    def initialize(
      api_key : String? = nil,
      base_url : String? = nil,
      default_model : String? = nil,
      timeout : Time::Span = 2.minutes
    )
      @config = ConfigLoader.instance
      @api_key = api_key || get_default_api_key
      @base_url = base_url || get_default_base_url
      @default_model = default_model || get_default_model
      @timeout = timeout

      validate_credentials!
    end

    # CLI-backed clients (which spawn an external binary that manages its own
    # credentials) override this to a no-op.
    protected def validate_credentials! : Nil
      raise APIError.new("API key is required for #{provider_name}") if @api_key.empty?
    end

    # Provider identification
    abstract def provider_name : String

    # Default configuration methods - override in subclasses
    protected abstract def get_default_api_key : String
    protected abstract def get_default_base_url : String
    protected abstract def get_default_model : String

    # Chat completion - the core method
    #
    # ```crystal
    # client = OpenAIClient.new
    # response = client.chat([
    #   Message.user("Hello, how are you?")
    # ])
    # puts response.content
    # ```
    abstract def chat(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil
    ) : ChatResponse(Nil)

    # Chat with structured output - returns parsed response
    # Note: This is implemented as a concrete method that delegates to chat_structured_impl
    # which subclasses must implement. This works around Crystal's limitations with
    # abstract generic methods.
    #
    # ```crystal
    # class PersonInfo < Llamero::BaseGrammar
    #   property name : String = ""
    #   property age : Int32 = 0
    # end
    #
    # response = client.chat_structured(
    #   [Message.user("Give me info about a random person")],
    #   PersonInfo
    # )
    # puts response.parsed.not_nil!.name
    # ```

    # Streaming chat completion
    #
    # ```crystal
    # client.chat_stream([Message.user("Tell me a story")]) do |chunk|
    #   print chunk
    # end
    # ```
    abstract def chat_stream(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
      &block : String -> Nil
    ) : Nil

    # Check if provider supports a specific feature
    abstract def supports?(feature : Feature) : Bool

    # Helper method to make HTTP requests
    protected def make_request(
      method : String,
      path : String,
      body : String? = nil,
      headers : HTTP::Headers = HTTP::Headers.new
    ) : HTTP::Client::Response
      uri = URI.parse(@base_url)

      HTTP::Client.new(uri) do |client|
        client.read_timeout = @timeout
        client.connect_timeout = 30.seconds

        # Add default headers
        headers["Content-Type"] = "application/json"
        add_auth_headers(headers)

        case method.upcase
        when "GET"
          client.get(request_path(path), headers: headers)
        when "POST"
          client.post(request_path(path), headers: headers, body: body)
        else
          raise APIError.new("Unsupported HTTP method: #{method}")
        end
      end
    end

    # HTTP::Client.new(uri) keeps only scheme/host/port, so any path prefix
    # in the base URL (e.g. Groq's "/openai", OpenRouter's "/api") must be
    # re-applied to each request path.
    protected def request_path(path : String) : String
      prefix = URI.parse(@base_url).path
      return path if prefix.empty? || prefix == "/"
      prefix.rstrip('/') + path
    end

    # Add authentication headers - override in subclasses for different auth patterns
    protected abstract def add_auth_headers(headers : HTTP::Headers) : Nil

    # Parse error response from API
    protected def parse_error_response(response : HTTP::Client::Response) : String
      begin
        json = JSON.parse(response.body)
        json["error"]?.try(&.["message"]?.try(&.as_s)) || response.body
      rescue
        response.body
      end
    end

    # Raise appropriate error for failed response
    # Uses specific error types for intelligent retry decisions
    protected def handle_error_response(response : HTTP::Client::Response) : NoReturn
      error_message = parse_error_response(response)
      provider = provider_name.downcase

      case response.status_code
      when 401, 403
        raise AuthenticationError.new(
          "#{provider_name} authentication failed: #{error_message}",
          response.status_code,
          response.body,
          provider
        )
      when 402
        raise QuotaExceededError.new(
          "#{provider_name} quota exceeded: #{error_message}",
          response.status_code,
          response.body,
          provider
        )
      when 404
        raise ModelNotFoundError.new(
          "#{provider_name} resource not found: #{error_message}",
          response.status_code,
          response.body,
          provider
        )
      when 429
        retry_after = parse_retry_after(response)
        raise RateLimitError.new(
          "#{provider_name} rate limit exceeded: #{error_message}",
          response.status_code,
          response.body,
          provider,
          retry_after
        )
      when 400
        raise InvalidRequestError.new(
          "#{provider_name} invalid request: #{error_message}",
          response.status_code,
          response.body,
          provider
        )
      when 500..599
        raise ServerError.new(
          "#{provider_name} server error: #{error_message}",
          response.status_code,
          response.body,
          provider
        )
      else
        raise APIError.new(
          "#{provider_name} API error: #{error_message}",
          status_code: response.status_code,
          response_body: response.body,
          provider: provider
        )
      end
    end

    # Parse Retry-After header if present
    private def parse_retry_after(response : HTTP::Client::Response) : Time::Span?
      if retry_after = response.headers["Retry-After"]?
        if seconds = retry_after.to_i?
          return seconds.seconds
        end
      end
      nil
    end
  end
end
