require "json"
require "digest/sha256"
require "./errors"

module Llamero::Native
  # One adapter within an adapter stack: a registered adapter name plus the
  # scale to apply its deltas at. Scale defaults to 1.0 and must be finite.
  struct AdapterSlot
    include JSON::Serializable

    getter name : String
    getter scale : Float64

    def initialize(@name : String, @scale : Float64 = 1.0)
      raise ArgumentError.new("Adapter name cannot be blank") if @name.blank?
      raise ArgumentError.new("Adapter scale must be finite, got #{@scale}") unless @scale.finite?
    end
  end

  # The set of adapters active for a request or session.
  #
  # An empty stack means "base model only". Activating a stack must never
  # reload the base model - that invariant is owned by ModelSession and the
  # bridge, but the stack carries the metadata to verify it.
  #
  # ```crystal
  # stack = Llamero::Native::AdapterStack.additive([
  #   Llamero::Native::AdapterSlot.new("sql", scale: 0.8),
  #   Llamero::Native::AdapterSlot.new("tone", scale: 0.4),
  # ])
  # ```
  struct AdapterStack
    include JSON::Serializable

    enum Mode
      # Adapter deltas compose additively. Ordering is recorded for
      # repeatability but is not semantically meaningful.
      Additive
      # Ordering is meaningful and requires a custom runtime path. This is
      # research behavior and must be opted into explicitly.
      Sequential
    end

    getter slots : Array(AdapterSlot)
    getter mode : Mode
    getter created_at : Time

    def self.additive(slots : Array(AdapterSlot) = [] of AdapterSlot) : AdapterStack
      new(slots, Mode::Additive)
    end

    # Sequential composition is experimental: adapter order changes results
    # and there is no stock LoRA runtime path for it yet.
    def self.sequential(slots : Array(AdapterSlot), experimental : Bool = false) : AdapterStack
      new(slots, Mode::Sequential, experimental: experimental)
    end

    # Convenience: base model only.
    def self.none : AdapterStack
      additive
    end

    def initialize(@slots : Array(AdapterSlot), @mode : Mode = Mode::Additive, experimental : Bool = false, @created_at : Time = Time.utc)
      if @mode.sequential? && !experimental
        raise ArgumentError.new(
          "Sequential adapter composition is experimental and not yet implemented by any bridge. " \
          "Pass experimental: true to acknowledge, or use AdapterStack.additive."
        )
      end

      names = @slots.map(&.name)
      duplicates = names.tally.select { |_, count| count > 1 }.keys
      unless duplicates.empty?
        raise ArgumentError.new("Adapter names must be unique within a stack, duplicated: #{duplicates.join(", ")}")
      end
    end

    def empty? : Bool
      @slots.empty?
    end

    # Stable identifier derived from the stack contents, used to tag events
    # and traces so runs are comparable.
    def stack_id : String
      return "base" if empty?
      digest = Digest::SHA256.new
      digest.update(@mode.to_s)
      @slots.each do |slot|
        digest.update(slot.name)
        digest.update(slot.scale.to_s)
      end
      digest.final.hexstring[0, 12]
    end
  end

  # A validated, registered adapter artifact on disk.
  struct AdapterDescriptor
    include JSON::Serializable

    getter name : String
    getter path : String
    getter checksum : String
    getter registered_at : Time

    def initialize(@name : String, @path : String, @checksum : String, @registered_at : Time = Time.utc)
    end
  end

  # Maps human-readable adapter names to validated local adapter artifacts.
  #
  # Registration validates that the path exists and contains adapter weights
  # (at least one `.safetensors` file), and computes a stable content checksum
  # so activations are traceable. Metadata lives here, separate from the
  # active runtime state on ModelSession.
  #
  # ```crystal
  # registry = Llamero::Native::AdapterRegistry.new
  # registry.register("sql", Path["adapters/sql"])
  # registry.register("support-tone", Path["adapters/support-tone"])
  # ```
  class AdapterRegistry
    def initialize
      @descriptors = {} of String => AdapterDescriptor
    end

    def register(name : String, path : Path | String) : AdapterDescriptor
      raise ArgumentError.new("Adapter name cannot be blank") if name.blank?
      dir = Path[path].expand

      unless Dir.exists?(dir)
        raise AdapterNotFoundError.new(name, "Adapter directory does not exist: #{dir}")
      end

      weight_files = Dir.glob(dir.join("*.safetensors").to_s).sort
      if weight_files.empty?
        raise AdapterActivationError.new(
          "Adapter directory #{dir} contains no .safetensors weight files",
          base_model_loaded: true
        )
      end

      descriptor = AdapterDescriptor.new(
        name: name,
        path: dir.to_s,
        checksum: compute_checksum(dir, weight_files)
      )
      @descriptors[name] = descriptor
      descriptor
    end

    def registered?(name : String) : Bool
      @descriptors.has_key?(name)
    end

    def lookup(name : String) : AdapterDescriptor
      @descriptors[name]? || raise AdapterNotFoundError.new(name)
    end

    def names : Array(String)
      @descriptors.keys
    end

    def size : Int32
      @descriptors.size
    end

    # Resolve every slot in a stack to its descriptor, raising
    # AdapterNotFoundError for the first unregistered name.
    def resolve(stack : AdapterStack) : Array({AdapterSlot, AdapterDescriptor})
      stack.slots.map { |slot| {slot, lookup(slot.name)} }
    end

    # Content checksum over the adapter's weight files and config, so the
    # same artifact always produces the same id in traces.
    private def compute_checksum(dir : Path, weight_files : Array(String)) : String
      digest = Digest::SHA256.new
      config = dir.join("adapter_config.json")
      files = weight_files.dup
      files << config.to_s if File.exists?(config)

      files.sort.each do |file|
        digest.update(File.basename(file))
        File.open(file) do |io|
          buffer = Bytes.new(65_536)
          while (read = io.read(buffer)) > 0
            digest.update(buffer[0, read])
          end
        end
      end
      digest.final.hexstring[0, 16]
    end
  end
end
