require "spec"
require "webmock"
require "../src/llamero"

# Reset WebMock and ConfigLoader before each test
Spec.before_each do
  WebMock.reset
  Llamero::ConfigLoader.reset!
  Llamero.reset_storage_root!
end

# Test Grammar classes for testing structured output
class TestPersonGrammar < Llamero::BaseGrammar
  property name : String = ""
  property age : Int32 = 0

  def initialize(@name = "", @age = 0)
  end
end

class TestAnalysisGrammar < Llamero::BaseGrammar
  property sentiment : String = ""
  property score : Float32 = 0.0
  property tags : Array(String) = [] of String

  def initialize(@sentiment = "", @score = 0.0_f32, @tags = [] of String)
  end
end

class NestedGrammar < Llamero::BaseGrammar
  property title : String = ""
  property person : TestPersonGrammar = TestPersonGrammar.new

  def initialize(@title = "", @person = TestPersonGrammar.new)
  end
end

# Helper module for creating test data
module TestHelpers
  # Create a simple user message array
  def self.user_messages(content : String) : Array(Llamero::Message)
    [Llamero::Message.user(content)]
  end

  # Create a conversation with system and user messages
  def self.conversation(system : String, user : String) : Array(Llamero::Message)
    [
      Llamero::Message.system(system),
      Llamero::Message.user(user),
    ]
  end

  # Mock OpenAI chat completion response
  def self.openai_chat_response(content : String, model : String = "gpt-4o") : String
    {
      id:      "chatcmpl-test123",
      object:  "chat.completion",
      created: Time.utc.to_unix,
      model:   model,
      choices: [
        {
          index:         0,
          message:       {role: "assistant", content: content},
          finish_reason: "stop",
        },
      ],
      usage: {
        prompt_tokens:     10,
        completion_tokens: 20,
        total_tokens:      30,
      },
    }.to_json
  end

  # Mock OpenAI error response
  def self.openai_error_response(message : String, type : String = "invalid_request_error") : String
    {
      error: {
        message: message,
        type:    type,
        param:   nil,
        code:    nil,
      },
    }.to_json
  end

  # Mock Anthropic chat response
  def self.anthropic_chat_response(content : String, model : String = "claude-sonnet-4-20250514") : String
    {
      id:            "msg_test123",
      type:          "message",
      role:          "assistant",
      content:       [{type: "text", text: content}],
      model:         model,
      stop_reason:   "end_turn",
      stop_sequence: nil,
      usage:         {input_tokens: 10, output_tokens: 20},
    }.to_json
  end

  # Mock Groq chat response (OpenAI-compatible)
  def self.groq_chat_response(content : String, model : String = "llama-3.3-70b-versatile") : String
    openai_chat_response(content, model)
  end

  # Mock OpenRouter chat response (OpenAI-compatible)
  def self.openrouter_chat_response(content : String, model : String = "openai/gpt-4o") : String
    openai_chat_response(content, model)
  end

  # Stub OpenAI API with success response
  def self.stub_openai_success(content : String = "Hello!")
    WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 200, body: openai_chat_response(content))
  end

  # Stub OpenAI API with rate limit error
  def self.stub_openai_rate_limit
    WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(
        status: 429,
        body: openai_error_response("Rate limit exceeded"),
        headers: HTTP::Headers{"Retry-After" => "1"}
      )
  end

  # Stub OpenAI API with auth error
  def self.stub_openai_auth_error
    WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 401, body: openai_error_response("Invalid API key"))
  end

  # Stub OpenAI API with server error
  def self.stub_openai_server_error
    WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
      .to_return(status: 500, body: openai_error_response("Internal server error"))
  end

  # Stub Anthropic API with success response
  def self.stub_anthropic_success(content : String = "Hello!")
    WebMock.stub(:post, "https://api.anthropic.com/v1/messages")
      .to_return(status: 200, body: anthropic_chat_response(content))
  end

  # Stub Groq API with success response
  def self.stub_groq_success(content : String = "Hello!")
    WebMock.stub(:post, "https://api.groq.com/openai/v1/chat/completions")
      .to_return(status: 200, body: groq_chat_response(content))
  end

  # Stub OpenRouter API with success response
  def self.stub_openrouter_success(content : String = "Hello!")
    WebMock.stub(:post, "https://openrouter.ai/api/v1/chat/completions")
      .to_return(status: 200, body: openrouter_chat_response(content))
  end

  # Set environment variables for testing
  def self.with_env(vars : Hash(String, String), &)
    original_values = {} of String => String?
    vars.each do |key, value|
      original_values[key] = ENV[key]?
      ENV[key] = value
    end

    begin
      yield
    ensure
      original_values.each do |key, value|
        if value
          ENV[key] = value
        else
          ENV.delete(key)
        end
      end
    end
  end

  # Helper to create a test client
  def self.create_test_client(primary : Symbol = :openai, fallbacks : Array(Symbol) = [] of Symbol)
    # Set up test API keys
    ENV["OPENAI_API_KEY"] = "test-openai-key"
    ENV["ANTHROPIC_API_KEY"] = "test-anthropic-key"
    ENV["GROQ_API_KEY"] = "test-groq-key"
    ENV["OPENROUTER_API_KEY"] = "test-openrouter-key"
    Llamero::ConfigLoader.reset!

    TestClient.new(primary, fallbacks)
  end
end

# Test client implementation
class TestClient < Llamero::Client
  def initialize(primary : Symbol, fallbacks : Array(Symbol) = [] of Symbol)
    super(primary: primary, fallbacks: fallbacks)
  end
end
