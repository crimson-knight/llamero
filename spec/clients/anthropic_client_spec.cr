require "../spec_helper"

describe Llamero::AnthropicClient do
  describe "#initialize" do
    it "creates client with API key from environment" do
      ENV["ANTHROPIC_API_KEY"] = "test-key"
      Llamero::ConfigLoader.reset!

      client = Llamero::AnthropicClient.new
      client.api_key.should eq("test-key")

      ENV.delete("ANTHROPIC_API_KEY")
    end

    it "creates client with explicit API key" do
      client = Llamero::AnthropicClient.new(api_key: "explicit-key")
      client.api_key.should eq("explicit-key")
    end

    it "raises error when no API key provided" do
      ENV.delete("ANTHROPIC_API_KEY")
      Llamero::ConfigLoader.reset!

      expect_raises(Llamero::APIError, /API key is required/) do
        Llamero::AnthropicClient.new
      end
    end

    it "uses correct base URL" do
      client = Llamero::AnthropicClient.new(api_key: "key")
      client.base_url.should eq("https://api.anthropic.com")
    end
  end

  describe "#provider_name" do
    it "returns Anthropic" do
      client = Llamero::AnthropicClient.new(api_key: "key")
      client.provider_name.should eq("Anthropic")
    end
  end

  describe "#supports?" do
    it "supports structured output" do
      client = Llamero::AnthropicClient.new(api_key: "key")
      client.supports?(Llamero::Feature::StructuredOutput).should be_true
    end

    it "supports tool calling" do
      client = Llamero::AnthropicClient.new(api_key: "key")
      client.supports?(Llamero::Feature::ToolCalling).should be_true
    end

    it "supports streaming" do
      client = Llamero::AnthropicClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Streaming).should be_true
    end

    it "does not support embeddings" do
      client = Llamero::AnthropicClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Embeddings).should be_false
    end

    it "supports vision" do
      client = Llamero::AnthropicClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Vision).should be_true
    end
  end

  describe "#chat" do
    it "sends chat request and returns response" do
      TestHelpers.stub_anthropic_success("Hello from Claude!")

      client = Llamero::AnthropicClient.new(api_key: "test-key")
      response = client.chat([Llamero::Message.user("Hi")])

      response.content.should eq("Hello from Claude!")
    end

    it "handles rate limit errors" do
      WebMock.stub(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 429,
          body: {error: {type: "rate_limit_error", message: "Rate limit exceeded"}}.to_json
        )

      client = Llamero::AnthropicClient.new(api_key: "test-key")

      expect_raises(Llamero::RateLimitError) do
        client.chat([Llamero::Message.user("Hi")])
      end
    end

    it "handles authentication errors" do
      WebMock.stub(:post, "https://api.anthropic.com/v1/messages")
        .to_return(
          status: 401,
          body: {error: {type: "authentication_error", message: "Invalid API key"}}.to_json
        )

      client = Llamero::AnthropicClient.new(api_key: "bad-key")

      expect_raises(Llamero::AuthenticationError) do
        client.chat([Llamero::Message.user("Hi")])
      end
    end
  end

  describe "#chat_structured" do
    it "sends structured output request" do
      response_body = {
        id:            "msg_test",
        type:          "message",
        role:          "assistant",
        content:       [{type: "text", text: %q({"name":"Bob","age":30})}],
        model:         "claude-sonnet-4-20250514",
        stop_reason:   "end_turn",
        stop_sequence: nil,
        usage:         {input_tokens: 10, output_tokens: 20},
      }.to_json

      WebMock.stub(:post, "https://api.anthropic.com/v1/messages")
        .to_return(status: 200, body: response_body)

      client = Llamero::AnthropicClient.new(api_key: "test-key")
      response = client.chat_structured(
        [Llamero::Message.user("Give me a person")],
        TestPersonGrammar
      )

      response.parsed.should_not be_nil
      response.parsed.not_nil!.name.should eq("Bob")
      response.parsed.not_nil!.age.should eq(30)
    end
  end
end
