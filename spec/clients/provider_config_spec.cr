require "../spec_helper"

describe Llamero::Provider do
  describe ".from_sym" do
    it "converts symbol to provider" do
      Llamero::Provider.from_sym(:openai).should eq(Llamero::Provider::OpenAI)
      Llamero::Provider.from_sym(:anthropic).should eq(Llamero::Provider::Anthropic)
      Llamero::Provider.from_sym(:groq).should eq(Llamero::Provider::Groq)
      Llamero::Provider.from_sym(:openrouter).should eq(Llamero::Provider::OpenRouter)
    end

    it "raises for unknown provider" do
      expect_raises(Llamero::APIError, /Unknown provider/) do
        Llamero::Provider.from_sym(:unknown)
      end
    end
  end

  describe "#to_sym" do
    it "converts provider to symbol" do
      Llamero::Provider::OpenAI.to_sym.should eq(:openai)
      Llamero::Provider::Anthropic.to_sym.should eq(:anthropic)
      Llamero::Provider::Groq.to_sym.should eq(:groq)
      Llamero::Provider::OpenRouter.to_sym.should eq(:openrouter)
    end
  end
end

describe Llamero::ProviderConfig do
  before_each do
    ENV["OPENAI_API_KEY"] = "test-openai-key"
    ENV["ANTHROPIC_API_KEY"] = "test-anthropic-key"
    Llamero::ConfigLoader.reset!
  end

  after_each do
    ENV.delete("OPENAI_API_KEY")
    ENV.delete("ANTHROPIC_API_KEY")
  end

  describe "#initialize" do
    it "creates config for OpenAI" do
      config = Llamero::ProviderConfig.new(:openai)
      config.provider.should eq(:openai)
    end

    it "creates config for Anthropic" do
      config = Llamero::ProviderConfig.new(:anthropic)
      config.provider.should eq(:anthropic)
    end
  end

  describe "#configured?" do
    it "returns true when provider has API key" do
      config = Llamero::ProviderConfig.new(:openai)
      config.configured?.should be_true
    end

    it "returns false when provider lacks API key" do
      ENV.delete("GROQ_API_KEY")
      Llamero::ConfigLoader.reset!

      config = Llamero::ProviderConfig.new(:groq)
      config.configured?.should be_false
    end
  end

  describe "#client" do
    it "returns OpenAI client for OpenAI provider" do
      config = Llamero::ProviderConfig.new(:openai)
      client = config.client

      client.should be_a(Llamero::OpenAIClient)
    end

    it "returns Anthropic client for Anthropic provider" do
      config = Llamero::ProviderConfig.new(:anthropic)
      client = config.client

      client.should be_a(Llamero::AnthropicClient)
    end

    it "caches client instance" do
      config = Llamero::ProviderConfig.new(:openai)
      client1 = config.client
      client2 = config.client

      client1.should be(client2)
    end
  end

  describe "#supports?" do
    it "delegates to client" do
      config = Llamero::ProviderConfig.new(:openai)

      config.supports?(Llamero::Feature::StructuredOutput).should be_true
      config.supports?(Llamero::Feature::Embeddings).should be_true
    end
  end
end
