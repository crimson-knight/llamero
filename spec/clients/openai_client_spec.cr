require "../spec_helper"

describe Llamero::OpenAIClient do
  describe "#initialize" do
    it "creates client with API key from environment" do
      ENV["OPENAI_API_KEY"] = "test-key"
      Llamero::ConfigLoader.reset!

      client = Llamero::OpenAIClient.new
      client.api_key.should eq("test-key")

      ENV.delete("OPENAI_API_KEY")
    end

    it "creates client with explicit API key" do
      client = Llamero::OpenAIClient.new(api_key: "explicit-key")
      client.api_key.should eq("explicit-key")
    end

    it "raises error when no API key provided" do
      ENV.delete("OPENAI_API_KEY")
      Llamero::ConfigLoader.reset!

      expect_raises(Llamero::APIError, /API key is required/) do
        Llamero::OpenAIClient.new
      end
    end

    it "uses default model" do
      client = Llamero::OpenAIClient.new(api_key: "key")
      client.default_model.should eq("gpt-4o")
    end

    it "allows custom default model" do
      client = Llamero::OpenAIClient.new(api_key: "key", default_model: "gpt-4o-mini")
      client.default_model.should eq("gpt-4o-mini")
    end
  end

  describe "#provider_name" do
    it "returns OpenAI" do
      client = Llamero::OpenAIClient.new(api_key: "key")
      client.provider_name.should eq("OpenAI")
    end
  end

  describe "#supports?" do
    it "supports structured output" do
      client = Llamero::OpenAIClient.new(api_key: "key")
      client.supports?(Llamero::Feature::StructuredOutput).should be_true
    end

    it "supports tool calling" do
      client = Llamero::OpenAIClient.new(api_key: "key")
      client.supports?(Llamero::Feature::ToolCalling).should be_true
    end

    it "supports streaming" do
      client = Llamero::OpenAIClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Streaming).should be_true
    end

    it "supports embeddings" do
      client = Llamero::OpenAIClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Embeddings).should be_true
    end

    it "supports vision" do
      client = Llamero::OpenAIClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Vision).should be_true
    end
  end

  describe "#chat" do
    it "sends chat request and returns response" do
      TestHelpers.stub_openai_success("Hello from GPT!")

      client = Llamero::OpenAIClient.new(api_key: "test-key")
      response = client.chat([Llamero::Message.user("Hi")])

      response.content.should eq("Hello from GPT!")
      response.model.should eq("gpt-4o")
    end

    it "includes usage information" do
      TestHelpers.stub_openai_success("Response")

      client = Llamero::OpenAIClient.new(api_key: "test-key")
      response = client.chat([Llamero::Message.user("Test")])

      response.usage.input_tokens.should eq(10)
      response.usage.output_tokens.should eq(20)
    end

    it "handles rate limit errors" do
      TestHelpers.stub_openai_rate_limit

      client = Llamero::OpenAIClient.new(api_key: "test-key")

      expect_raises(Llamero::RateLimitError) do
        client.chat([Llamero::Message.user("Hi")])
      end
    end

    it "handles authentication errors" do
      TestHelpers.stub_openai_auth_error

      client = Llamero::OpenAIClient.new(api_key: "bad-key")

      expect_raises(Llamero::AuthenticationError) do
        client.chat([Llamero::Message.user("Hi")])
      end
    end

    it "handles server errors" do
      TestHelpers.stub_openai_server_error

      client = Llamero::OpenAIClient.new(api_key: "test-key")

      expect_raises(Llamero::ServerError) do
        client.chat([Llamero::Message.user("Hi")])
      end
    end
  end

  describe "#chat_structured" do
    it "sends structured output request" do
      response_body = {
        id:      "chatcmpl-test",
        object:  "chat.completion",
        model:   "gpt-4o",
        choices: [{
          index:         0,
          message:       {role: "assistant", content: %q({"name":"Alice","age":25})},
          finish_reason: "stop",
        }],
        usage: {prompt_tokens: 10, completion_tokens: 20, total_tokens: 30},
      }.to_json

      WebMock.stub(:post, "https://api.openai.com/v1/chat/completions")
        .to_return(status: 200, body: response_body)

      client = Llamero::OpenAIClient.new(api_key: "test-key")
      response = client.chat_structured(
        [Llamero::Message.user("Give me a person")],
        TestPersonGrammar
      )

      response.parsed.should_not be_nil
      response.parsed.not_nil!.name.should eq("Alice")
      response.parsed.not_nil!.age.should eq(25)
    end
  end
end
