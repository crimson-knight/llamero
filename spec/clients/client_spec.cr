require "../spec_helper"

describe Llamero::Client do
  before_each do
    ENV["OPENAI_API_KEY"] = "test-openai-key"
    ENV["ANTHROPIC_API_KEY"] = "test-anthropic-key"
    ENV["GROQ_API_KEY"] = "test-groq-key"
    ENV["OPENROUTER_API_KEY"] = "test-openrouter-key"
    Llamero::ConfigLoader.reset!
  end

  after_each do
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("ANTHROPIC_API_KEY")
    ENV.delete("GROQ_API_KEY")
    ENV.delete("OPENROUTER_API_KEY")
  end

  describe "#initialize" do
    it "creates client with primary provider" do
      client = TestClient.new(:openai)
      client.providers.size.should be >= 1
    end

    it "creates client with fallback providers" do
      client = TestClient.new(:openai, [:anthropic, :groq])
      client.available_providers.should contain(:openai)
    end

    it "raises when no providers configured" do
      ENV.delete("OPENAI_API_KEY")
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("GROQ_API_KEY")
      ENV.delete("OPENROUTER_API_KEY")
      Llamero::ConfigLoader.reset!

      expect_raises(Llamero::APIError, /No providers configured/) do
        TestClient.new(:openai)
      end
    end
  end

  describe "#available_providers" do
    it "returns list of configured providers" do
      client = TestClient.new(:openai, [:anthropic])
      providers = client.available_providers

      providers.should contain(:openai)
      providers.should contain(:anthropic)
    end
  end

  describe "#chat" do
    it "uses primary provider on success" do
      TestHelpers.stub_openai_success("Hello!")

      client = TestClient.new(:openai, [:anthropic])
      response = client.chat([Llamero::Message.user("Hi")])

      response.content.should eq("Hello!")
      response.provider_used.should eq(:openai)
      response.attempts.should eq(1)
    end

    it "fails over on auth error" do
      # OpenAI fails with auth error
      WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 401, body: TestHelpers.openai_error_response("Invalid key"))

      # Anthropic succeeds
      TestHelpers.stub_anthropic_success("Hello from Anthropic!")

      client = TestClient.new(:openai, [:anthropic])
      response = client.chat([Llamero::Message.user("Hi")])

      response.content.should eq("Hello from Anthropic!")
      response.provider_used.should eq(:anthropic)
    end

    it "raises when all providers fail" do
      WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 401, body: TestHelpers.openai_error_response("Invalid key"))

      WebMock.stub(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 401, body: {error: {message: "Invalid key"}}.to_json)

      client = TestClient.new(:openai, [:anthropic])

      expect_raises(Llamero::APIError, /All .* providers failed/) do
        client.chat([Llamero::Message.user("Hi")])
      end
    end
  end

  describe "#chat_structured" do
    it "returns parsed response" do
      response_body = {
        id:      "chatcmpl-test",
        object:  "chat.completion",
        model:   "gpt-4o",
        choices: [{
          index:         0,
          message:       {role: "assistant", content: %q({"name":"Test","age":42})},
          finish_reason: "stop",
        }],
        usage: {prompt_tokens: 10, completion_tokens: 20, total_tokens: 30},
      }.to_json

      WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 200, body: response_body)

      client = TestClient.new(:openai)
      response = client.chat_structured(
        [Llamero::Message.user("Give me a person")],
        TestPersonGrammar
      )

      response.parsed.should_not be_nil
      response.parsed.not_nil!.name.should eq("Test")
      response.parsed.not_nil!.age.should eq(42)
    end
  end

  describe "#on_fallback" do
    it "calls callback on failover" do
      WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 401, body: TestHelpers.openai_error_response("Invalid key"))
      TestHelpers.stub_anthropic_success("Success")

      fallback_called = false
      from_provider = :unknown
      to_provider = :unknown

      client = TestClient.new(:openai, [:anthropic])
      client.on_fallback do |from, to, error|
        fallback_called = true
        from_provider = from
        to_provider = to
      end

      client.chat([Llamero::Message.user("Hi")])

      fallback_called.should be_true
      from_provider.should eq(:openai)
      to_provider.should eq(:anthropic)
    end
  end

  describe "#providers_for_features" do
    it "filters providers by features" do
      client = TestClient.new(:openai, [:anthropic])

      # Both support structured output
      providers = client.providers_for_features([Llamero::Feature::StructuredOutput])
      providers.should contain(:openai)
      providers.should contain(:anthropic)

      # Only OpenAI supports embeddings
      embedding_providers = client.providers_for_features([Llamero::Feature::Embeddings])
      embedding_providers.should contain(:openai)
      embedding_providers.should_not contain(:anthropic)
    end
  end

  describe "#supports_features?" do
    it "returns true when at least one provider supports features" do
      client = TestClient.new(:openai, [:anthropic])

      client.supports_features?([Llamero::Feature::StructuredOutput]).should be_true
      client.supports_features?([Llamero::Feature::Embeddings]).should be_true
    end

    it "returns false when no provider supports features" do
      # Create client with only Anthropic (no embeddings support)
      ENV.delete("OPENAI_API_KEY")
      ENV.delete("GROQ_API_KEY")
      ENV.delete("OPENROUTER_API_KEY")
      Llamero::ConfigLoader.reset!

      client = TestClient.new(:anthropic)
      client.supports_features?([Llamero::Feature::Embeddings]).should be_false
    end
  end
end
