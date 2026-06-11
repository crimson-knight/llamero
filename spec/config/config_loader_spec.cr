require "../spec_helper"

describe Llamero::ConfigLoader do
  describe "#initialize" do
    it "loads API keys from environment variables" do
      ENV["OPENAI_API_KEY"] = "env-openai-key"
      ENV["ANTHROPIC_API_KEY"] = "env-anthropic-key"
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new
      config.openai_api_key.should eq("env-openai-key")
      config.anthropic_api_key.should eq("env-anthropic-key")

      ENV.delete("OPENAI_API_KEY")
      ENV.delete("ANTHROPIC_API_KEY")
    end

    it "prefers explicit values over environment variables" do
      ENV["OPENAI_API_KEY"] = "env-key"
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new(openai_api_key: "explicit-key")
      config.openai_api_key.should eq("explicit-key")

      ENV.delete("OPENAI_API_KEY")
    end

    it "has sensible defaults" do
      # Clear all env vars
      ENV.delete("OPENAI_API_KEY")
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("GROQ_API_KEY")
      ENV.delete("OPENROUTER_API_KEY")
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new
      config.default_provider.should eq("openai")
      config.default_model.should eq("gpt-4o")
      config.default_temperature.should eq(0.7_f32)
      config.default_max_tokens.should eq(4096)
    end

    it "allows overriding defaults" do
      config = Llamero::ConfigLoader.new(
        default_provider: "anthropic",
        default_model: "claude-3-opus",
        default_temperature: 0.5_f32,
        default_max_tokens: 2048
      )
      config.default_provider.should eq("anthropic")
      config.default_model.should eq("claude-3-opus")
      config.default_temperature.should eq(0.5_f32)
      config.default_max_tokens.should eq(2048)
    end
  end

  describe "#api_key_for" do
    it "returns the correct API key for each provider" do
      ENV["OPENAI_API_KEY"] = "openai-key"
      ENV["ANTHROPIC_API_KEY"] = "anthropic-key"
      ENV["GROQ_API_KEY"] = "groq-key"
      ENV["OPENROUTER_API_KEY"] = "openrouter-key"
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new

      config.api_key_for("openai").should eq("openai-key")
      config.api_key_for("anthropic").should eq("anthropic-key")
      config.api_key_for("groq").should eq("groq-key")
      config.api_key_for("openrouter").should eq("openrouter-key")

      ENV.delete("OPENAI_API_KEY")
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("GROQ_API_KEY")
      ENV.delete("OPENROUTER_API_KEY")
    end

    it "returns nil for unknown provider" do
      config = Llamero::ConfigLoader.new
      config.api_key_for("unknown").should be_nil
    end

    it "is case insensitive" do
      ENV["OPENAI_API_KEY"] = "key"
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new
      config.api_key_for("OpenAI").should eq("key")
      config.api_key_for("OPENAI").should eq("key")
      config.api_key_for("openai").should eq("key")

      ENV.delete("OPENAI_API_KEY")
    end
  end

  describe "#provider_configured?" do
    it "returns true when provider has an API key" do
      ENV["OPENAI_API_KEY"] = "key"
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new
      config.provider_configured?("openai").should be_true

      ENV.delete("OPENAI_API_KEY")
    end

    it "returns false when provider has no API key" do
      ENV.delete("OPENAI_API_KEY")
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new
      config.provider_configured?("openai").should be_false
    end
  end

  describe "#configured_providers" do
    it "returns list of providers with API keys" do
      ENV["OPENAI_API_KEY"] = "key1"
      ENV["ANTHROPIC_API_KEY"] = "key2"
      ENV.delete("GROQ_API_KEY")
      ENV.delete("OPENROUTER_API_KEY")
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new
      providers = config.configured_providers

      providers.should contain("openai")
      providers.should contain("anthropic")
      providers.should_not contain("groq")
      providers.should_not contain("openrouter")

      ENV.delete("OPENAI_API_KEY")
      ENV.delete("ANTHROPIC_API_KEY")
    end

    it "returns empty array when no providers configured" do
      ENV.delete("OPENAI_API_KEY")
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("GROQ_API_KEY")
      ENV.delete("OPENROUTER_API_KEY")
      Llamero::ConfigLoader.reset!

      config = Llamero::ConfigLoader.new
      config.configured_providers.should be_empty
    end
  end

  describe ".instance" do
    it "returns singleton instance" do
      ENV["OPENAI_API_KEY"] = "singleton-key"
      Llamero::ConfigLoader.reset!

      instance1 = Llamero::ConfigLoader.instance
      instance2 = Llamero::ConfigLoader.instance

      instance1.should be(instance2)
      instance1.openai_api_key.should eq("singleton-key")

      ENV.delete("OPENAI_API_KEY")
    end
  end

  describe ".reset!" do
    it "clears the singleton instance" do
      ENV["OPENAI_API_KEY"] = "first-key"
      Llamero::ConfigLoader.reset!
      instance1 = Llamero::ConfigLoader.instance

      ENV["OPENAI_API_KEY"] = "second-key"
      Llamero::ConfigLoader.reset!
      instance2 = Llamero::ConfigLoader.instance

      instance1.openai_api_key.should eq("first-key")
      instance2.openai_api_key.should eq("second-key")
      instance1.should_not be(instance2)

      ENV.delete("OPENAI_API_KEY")
    end
  end
end
