require "../spec_helper"

describe Llamero::OpenRouterClient do
  describe "#initialize" do
    it "creates client with API key from environment" do
      ENV["OPENROUTER_API_KEY"] = "test-key"
      Llamero::ConfigLoader.reset!

      client = Llamero::OpenRouterClient.new
      client.api_key.should eq("test-key")

      ENV.delete("OPENROUTER_API_KEY")
    end

    it "creates client with explicit API key" do
      client = Llamero::OpenRouterClient.new(api_key: "explicit-key")
      client.api_key.should eq("explicit-key")
    end

    it "uses correct base URL" do
      client = Llamero::OpenRouterClient.new(api_key: "key")
      client.base_url.should eq("https://openrouter.ai/api")
    end

    it "uses correct default model" do
      client = Llamero::OpenRouterClient.new(api_key: "key")
      client.default_model.should eq("openai/gpt-4o")
    end
  end

  describe "#provider_name" do
    it "returns OpenRouter" do
      client = Llamero::OpenRouterClient.new(api_key: "key")
      client.provider_name.should eq("OpenRouter")
    end
  end

  describe "#supports?" do
    it "supports all features (model dependent)" do
      client = Llamero::OpenRouterClient.new(api_key: "key")
      client.supports?(Llamero::Feature::StructuredOutput).should be_true
      client.supports?(Llamero::Feature::ToolCalling).should be_true
      client.supports?(Llamero::Feature::Streaming).should be_true
      client.supports?(Llamero::Feature::Embeddings).should be_true
      client.supports?(Llamero::Feature::Vision).should be_true
    end
  end

  describe "#chat" do
    it "sends chat request and returns response" do
      TestHelpers.stub_openrouter_success("Hello from OpenRouter!")

      client = Llamero::OpenRouterClient.new(api_key: "test-key")
      response = client.chat([Llamero::Message.user("Hi")])

      response.content.should eq("Hello from OpenRouter!")
    end
  end
end
