require "yaml"

module Llamero
  # Configuration loader that reads from .llamero/config.yml (project-relative) with ENV variable fallback
  #
  # Priority order:
  # 1. Explicit values passed to constructor
  # 2. Environment variables (OPENAI_API_KEY, ANTHROPIC_API_KEY, etc.)
  # 3. Config file (.llamero/config.yml in current working directory)
  # 4. Default values
  #
  # The config file is relative to `Dir.current` (the directory where the binary runs),
  # making it easy to have different configurations per project.
  class ConfigLoader
    # Config file path relative to current working directory
    CONFIG_FILE_PATH = Path[".llamero/config.yml"]

    # Provider credentials
    getter openai_api_key : String?
    getter openai_organization : String?
    getter anthropic_api_key : String?
    getter groq_api_key : String?
    getter openrouter_api_key : String?

    # Default settings
    getter default_provider : String
    getter default_model : String
    getter default_temperature : Float32
    getter default_max_tokens : Int32

    def initialize(
      openai_api_key : String? = nil,
      openai_organization : String? = nil,
      anthropic_api_key : String? = nil,
      groq_api_key : String? = nil,
      openrouter_api_key : String? = nil,
      default_provider : String? = nil,
      default_model : String? = nil,
      default_temperature : Float32? = nil,
      default_max_tokens : Int32? = nil
    )
      # Load config file if it exists
      config = load_config_file

      # Provider credentials: explicit > ENV > config file
      @openai_api_key = openai_api_key || ENV["OPENAI_API_KEY"]? || config.dig?("providers", "openai", "api_key").try(&.as_s)
      @openai_organization = openai_organization || ENV["OPENAI_ORGANIZATION"]? || config.dig?("providers", "openai", "organization").try(&.as_s)
      @anthropic_api_key = anthropic_api_key || ENV["ANTHROPIC_API_KEY"]? || config.dig?("providers", "anthropic", "api_key").try(&.as_s)
      @groq_api_key = groq_api_key || ENV["GROQ_API_KEY"]? || config.dig?("providers", "groq", "api_key").try(&.as_s)
      @openrouter_api_key = openrouter_api_key || ENV["OPENROUTER_API_KEY"]? || config.dig?("providers", "openrouter", "api_key").try(&.as_s)

      # Default settings: explicit > config file > hardcoded defaults
      @default_provider = default_provider || config.dig?("defaults", "provider").try(&.as_s) || "openai"
      @default_model = default_model || config.dig?("defaults", "model").try(&.as_s) || "gpt-4o"
      @default_temperature = default_temperature || config.dig?("defaults", "temperature").try(&.as_f.to_f32) || 0.7_f32
      @default_max_tokens = default_max_tokens || config.dig?("defaults", "max_tokens").try(&.as_i) || 4096
    end

    # Get API key for a specific provider
    def api_key_for(provider : String) : String?
      case provider.downcase
      when "openai"    then @openai_api_key
      when "anthropic" then @anthropic_api_key
      when "groq"      then @groq_api_key
      when "openrouter" then @openrouter_api_key
      else nil
      end
    end

    # Check if a provider is configured (has an API key)
    def provider_configured?(provider : String) : Bool
      !api_key_for(provider).nil?
    end

    # List all configured providers
    def configured_providers : Array(String)
      providers = [] of String
      providers << "openai" if @openai_api_key
      providers << "anthropic" if @anthropic_api_key
      providers << "groq" if @groq_api_key
      providers << "openrouter" if @openrouter_api_key
      providers
    end

    # Singleton instance for convenience
    @@instance : ConfigLoader?

    def self.instance : ConfigLoader
      @@instance ||= new
    end

    def self.reset!
      @@instance = nil
    end

    # Get the absolute path to the config file (relative to current working directory)
    def self.config_file_path : Path
      Path[Dir.current] / CONFIG_FILE_PATH
    end

    private def load_config_file : YAML::Any
      path = ConfigLoader.config_file_path
      if File.exists?(path)
        YAML.parse(File.read(path))
      else
        YAML.parse("{}")
      end
    rescue ex : YAML::ParseException
      # If config file is malformed, log warning and return empty config
      STDERR.puts "Warning: Could not parse config file at #{path}: #{ex.message}"
      YAML.parse("{}")
    end
  end

  # Convenience method to access config
  def self.config : ConfigLoader
    ConfigLoader.instance
  end
end
