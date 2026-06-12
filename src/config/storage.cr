module Llamero
  module Storage
    ENV_VAR          = "LLAMERO_HOME"
    DEFAULT_BASENAME = ".llamero"

    @@root_override : Path?

    def self.root : Path
      @@root_override || env_root || default_root
    end

    def self.root=(path : Path | String) : Path
      @@root_override = Path[path].expand
    end

    def self.configured? : Bool
      !@@root_override.nil? || env_root_configured?
    end

    def self.models_dir : Path
      root.join("models")
    end

    def self.adapters_dir : Path
      root.join("adapters")
    end

    def self.lib_dir : Path
      root.join("lib")
    end

    def self.audio_models_dir : Path
      root.join("audio_models")
    end

    def self.path(*parts : String) : Path
      parts.reduce(root) { |path, part| path.join(part) }
    end

    # :nodoc:
    def self.reset! : Nil
      @@root_override = nil
    end

    private def self.default_root : Path
      Path.home.join(DEFAULT_BASENAME)
    end

    private def self.env_root : Path?
      raw = ENV[ENV_VAR]?
      return nil unless raw
      value = raw.strip
      return nil if value.empty?
      Path[value].expand
    end

    private def self.env_root_configured? : Bool
      raw = ENV[ENV_VAR]?
      !!raw && !raw.strip.empty?
    end
  end

  def self.storage_root : Path
    Storage.root
  end

  def self.storage_root=(path : Path | String) : Path
    Storage.root = path
  end

  def self.storage_path(*parts : String) : Path
    Storage.path(*parts)
  end

  # :nodoc:
  def self.reset_storage_root! : Nil
    Storage.reset!
  end
end
