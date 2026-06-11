require "../spec_helper"

describe Llamero::GroqClient do
  describe "#initialize" do
    it "creates client with API key from environment" do
      ENV["GROQ_API_KEY"] = "test-key"
      Llamero::ConfigLoader.reset!

      client = Llamero::GroqClient.new
      client.api_key.should eq("test-key")

      ENV.delete("GROQ_API_KEY")
    end

    it "creates client with explicit API key" do
      client = Llamero::GroqClient.new(api_key: "explicit-key")
      client.api_key.should eq("explicit-key")
    end

    it "uses correct base URL" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.base_url.should eq("https://api.groq.com/openai")
    end

    it "uses correct default model" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.default_model.should eq("llama-3.3-70b-versatile")
    end
  end

  describe "#provider_name" do
    it "returns Groq" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.provider_name.should eq("Groq")
    end
  end

  describe "#supports?" do
    it "supports structured output" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.supports?(Llamero::Feature::StructuredOutput).should be_true
    end

    it "supports tool calling" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.supports?(Llamero::Feature::ToolCalling).should be_true
    end

    it "supports streaming" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Streaming).should be_true
    end

    it "does not support embeddings" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Embeddings).should be_false
    end

    it "supports vision" do
      client = Llamero::GroqClient.new(api_key: "key")
      client.supports?(Llamero::Feature::Vision).should be_true
    end
  end

  describe "#chat" do
    it "sends chat request and returns response" do
      TestHelpers.stub_groq_success("Hello from Groq!")

      client = Llamero::GroqClient.new(api_key: "test-key")
      response = client.chat([Llamero::Message.user("Hi")])

      response.content.should eq("Hello from Groq!")
    end
  end
end
