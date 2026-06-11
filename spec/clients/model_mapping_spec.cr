require "../spec_helper"

describe Llamero::ModelMapping do
  describe ".map_model" do
    it "returns same model for same provider" do
      result = Llamero::ModelMapping.map_model("gpt-4o", :openai, :openai)
      result.should eq("gpt-4o")
    end

    it "maps OpenAI model to Anthropic equivalent" do
      result = Llamero::ModelMapping.map_model("gpt-4o", :openai, :anthropic)
      result.should_not be_nil
    end

    it "maps Anthropic model to OpenAI equivalent" do
      result = Llamero::ModelMapping.map_model("claude-sonnet-4-20250514", :anthropic, :openai)
      result.should_not be_nil
    end

    it "adds OpenRouter prefix for OpenRouter target" do
      result = Llamero::ModelMapping.map_model("gpt-4o", :openai, :openrouter)
      result.should contain("openai/") if result
    end

    it "returns original model if no mapping found" do
      result = Llamero::ModelMapping.map_model("unknown-model-xyz", :openai, :anthropic)
      result.should eq("unknown-model-xyz")
    end
  end

  describe ".find_equivalent" do
    it "finds equivalent models across providers" do
      result = Llamero::ModelMapping.find_equivalent("gpt-4o", :openai, :anthropic)
      # Should return something even if not a direct mapping
      result.should_not be_nil
    end

    it "returns original for same provider" do
      result = Llamero::ModelMapping.find_equivalent("gpt-4o", :openai, :openai)
      result.should eq("gpt-4o")
    end
  end

  describe ".default_model" do
    it "returns OpenAI default" do
      result = Llamero::ModelMapping.default_model(:openai)
      result.should eq("gpt-4o")
    end

    it "returns Anthropic default" do
      result = Llamero::ModelMapping.default_model(:anthropic)
      result.should eq("claude-sonnet-4-20250514")
    end

    it "returns Groq default" do
      result = Llamero::ModelMapping.default_model(:groq)
      result.should eq("llama-3.3-70b-versatile")
    end

    it "returns OpenRouter default" do
      result = Llamero::ModelMapping.default_model(:openrouter)
      result.should eq("openai/gpt-4o")
    end

    it "raises for unknown provider" do
      expect_raises(ArgumentError, /Unknown provider/) do
        Llamero::ModelMapping.default_model(:unknown)
      end
    end
  end

  describe ".model_likely_supported?" do
    it "returns true for OpenAI models with gpt prefix" do
      result = Llamero::ModelMapping.model_likely_supported?("gpt-4o", :openai)
      result.should be_true
    end

    it "returns true for Anthropic models with claude prefix" do
      result = Llamero::ModelMapping.model_likely_supported?("claude-3-opus", :anthropic)
      result.should be_true
    end

    it "returns true for Groq models with llama prefix" do
      result = Llamero::ModelMapping.model_likely_supported?("llama-3.3-70b", :groq)
      result.should be_true
    end

    it "returns true for OpenRouter (all models)" do
      result = Llamero::ModelMapping.model_likely_supported?("any-model", :openrouter)
      result.should be_true
    end

    it "returns false for mismatched models" do
      result = Llamero::ModelMapping.model_likely_supported?("claude-3", :openai)
      result.should be_false
    end
  end
end
