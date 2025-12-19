module Llamero
  # Maps model names across providers for failover scenarios
  #
  # When falling back to a different provider, this module helps find
  # an equivalent model that provides similar capabilities.
  #
  # ```crystal
  # # Map gpt-4o to equivalent Claude model
  # equivalent = ModelMapping.map_model("gpt-4o", :openai, :anthropic)
  # # => "claude-sonnet-4-20250514"
  # ```
  module ModelMapping
    # Model equivalence classes - groups of roughly equivalent models
    # Key is a canonical name, value is a hash of provider-specific names
    EQUIVALENCE_CLASSES = {
      # Top tier models
      "top-tier" => {
        :openai     => "gpt-4o",
        :anthropic  => "claude-sonnet-4-20250514",
        :groq       => "llama-3.3-70b-versatile",
        :openrouter => "openai/gpt-4o",
      },
      # Fast/cheap tier
      "fast-tier" => {
        :openai     => "gpt-4o-mini",
        :anthropic  => "claude-3-5-haiku-20241022",
        :groq       => "llama-3.1-8b-instant",
        :openrouter => "openai/gpt-4o-mini",
      },
      # Premium tier (most capable)
      "premium-tier" => {
        :openai     => "gpt-4o",
        :anthropic  => "claude-opus-4-20250514",
        :groq       => "llama-3.3-70b-versatile",
        :openrouter => "anthropic/claude-opus-4-20250514",
      },
    }

    # Direct model mappings for specific models
    DIRECT_MAPPINGS = {
      # OpenAI models
      "gpt-4o" => {
        :anthropic  => "claude-sonnet-4-20250514",
        :groq       => "llama-3.3-70b-versatile",
        :openrouter => "openai/gpt-4o",
      },
      "gpt-4o-mini" => {
        :anthropic  => "claude-3-5-haiku-20241022",
        :groq       => "llama-3.1-8b-instant",
        :openrouter => "openai/gpt-4o-mini",
      },
      "gpt-4-turbo" => {
        :anthropic  => "claude-sonnet-4-20250514",
        :groq       => "llama-3.3-70b-versatile",
        :openrouter => "openai/gpt-4-turbo",
      },
      # Anthropic models
      "claude-sonnet-4-20250514" => {
        :openai     => "gpt-4o",
        :groq       => "llama-3.3-70b-versatile",
        :openrouter => "anthropic/claude-sonnet-4-20250514",
      },
      "claude-opus-4-20250514" => {
        :openai     => "gpt-4o",
        :groq       => "llama-3.3-70b-versatile",
        :openrouter => "anthropic/claude-opus-4-20250514",
      },
      "claude-3-5-haiku-20241022" => {
        :openai     => "gpt-4o-mini",
        :groq       => "llama-3.1-8b-instant",
        :openrouter => "anthropic/claude-3-5-haiku-20241022",
      },
      # Groq/Llama models
      "llama-3.3-70b-versatile" => {
        :openai     => "gpt-4o",
        :anthropic  => "claude-sonnet-4-20250514",
        :openrouter => "meta-llama/llama-3.3-70b-instruct",
      },
      "llama-3.1-8b-instant" => {
        :openai     => "gpt-4o-mini",
        :anthropic  => "claude-3-5-haiku-20241022",
        :openrouter => "meta-llama/llama-3.1-8b-instruct",
      },
    }

    # OpenRouter prefixes for common model families
    OPENROUTER_PREFIXES = {
      "gpt"     => "openai/",
      "claude"  => "anthropic/",
      "llama"   => "meta-llama/",
      "mixtral" => "mistralai/",
      "gemini"  => "google/",
      "gemma"   => "google/",
    }

    # Get equivalent model for target provider
    #
    # ```crystal
    # ModelMapping.map_model("gpt-4o", :openai, :anthropic)
    # # => "claude-sonnet-4-20250514"
    #
    # ModelMapping.map_model("unknown-model", :openai, :anthropic)
    # # => "unknown-model" (returns original if no mapping found)
    # ```
    def self.map_model(model : String, from_provider : Symbol, to_provider : Symbol) : String
      return model if from_provider == to_provider

      # Check direct mappings first
      if mappings = DIRECT_MAPPINGS[model]?
        if mapped = mappings[to_provider]?
          return mapped
        end
      end

      # For OpenRouter target, add appropriate prefix
      if to_provider == :openrouter && !model.includes?("/")
        OPENROUTER_PREFIXES.each do |prefix, namespace|
          if model.starts_with?(prefix)
            return "#{namespace}#{model}"
          end
        end
      end

      # Return original model if no mapping found
      model
    end

    # Check if a model is likely supported by a provider (heuristic)
    def self.model_likely_supported?(model : String, provider : Symbol) : Bool
      case provider
      when :openai
        model.starts_with?("gpt") || model.starts_with?("o1") || model.starts_with?("o3")
      when :anthropic
        model.starts_with?("claude")
      when :groq
        model.starts_with?("llama") || model.starts_with?("mixtral") || model.starts_with?("gemma")
      when :openrouter
        true # OpenRouter supports almost everything
      else
        false
      end
    end

    # Get the default model for a provider
    def self.default_model(provider : Symbol) : String
      case provider
      when :openai     then "gpt-4o"
      when :anthropic  then "claude-sonnet-4-20250514"
      when :groq       then "llama-3.3-70b-versatile"
      when :openrouter then "openai/gpt-4o"
      else
        raise ArgumentError.new("Unknown provider: #{provider}")
      end
    end

    # Find the best equivalent model for a target provider
    # Uses tier matching when direct mapping not available
    def self.find_equivalent(model : String, from_provider : Symbol, to_provider : Symbol) : String
      # Try direct mapping first
      mapped = map_model(model, from_provider, to_provider)
      return mapped if mapped != model

      # Fall back to tier-based matching
      EQUIVALENCE_CLASSES.each do |_tier_name, tier_models|
        if tier_models[from_provider]? == model
          if equivalent = tier_models[to_provider]?
            return equivalent
          end
        end
      end

      # Last resort: return provider's default model
      default_model(to_provider)
    end
  end
end
