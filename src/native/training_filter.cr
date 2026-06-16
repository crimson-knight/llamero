require "json"
require "./adapters"
require "../config/storage"

module Llamero::Native
  # A distributable **training filter**: a trained LoRA adapter packaged with a
  # manifest so any consumer can discover it, verify its integrity, confirm it
  # targets their base model, and activate it. This is the unit a library author
  # ships alongside their library — load the filter and an assistant instantly
  # has accurate working knowledge of that library's API and idioms.
  #
  # On disk a package is a directory:
  #
  # ```text
  # <pkg>/
  #   training_filter.json   # the manifest (TrainingFilter::Manifest)
  #   adapter_config.json    # the LoRA config the bridge applies
  #   *.safetensors          # the adapter weights
  # ```
  #
  # ```crystal
  # # Author side: package a trained adapter for distribution.
  # filter = Llamero::Native::TrainingFilter.pack(
  #   adapter_dir: descriptor.path,
  #   dest:        Path["dist/amber.filter"],
  #   name:        "amber",
  #   version:     "0.1.0",
  #   base_model:  "mlx-community/gemma-3-1b-it-4bit",
  #   lora:        Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 8),
  #   provenance:  Llamero::Native::TrainingFilter::Provenance.new(methods: ["unsupervised", "sft"]),
  #   base_filter: "crystal@0.1.0",       # fused-forward atop the Crystal base
  #   library:     "amber", library_version: "2.0.0-dev",
  #   metrics:     {"compile" => 0.93, "format" => 0.97},
  # )
  #
  # # Consumer side: discover filters that fit my base, verify, and activate one.
  # session.load_model
  # Llamero::Native::TrainingFilter.installed(base_model: session.model_id).each do |f|
  #   session.activate_filter(f, fuse: true) if f.library == "amber"
  # end
  # ```
  class TrainingFilter
    MANIFEST_FILE = "training_filter.json"

    # The LoRA shape the adapter was trained with, so a consumer or registry can
    # sanity-check compatibility and reproduce activation.
    struct LoRASpec
      include JSON::Serializable
      getter rank : Int32
      getter scale : Float64
      getter num_layers : Int32

      def initialize(@rank : Int32, @scale : Float64, @num_layers : Int32)
      end
    end

    # How the filter was produced — which training methods, the corpus it was
    # trained on, and by what tool. Honest provenance so consumers can trust it.
    struct Provenance
      include JSON::Serializable
      getter methods : Array(String)        # e.g. ["unsupervised", "sft", "grpo"]
      getter dataset_checksum : String?     # content hash of the training corpus
      getter generator : String?            # tool/version that produced the filter
      getter created_at : Time

      def initialize(
        @methods : Array(String),
        @dataset_checksum : String? = nil,
        @generator : String? = nil,
        @created_at : Time = Time.utc,
      )
      end
    end

    # The manifest serialized to `training_filter.json`.
    struct Manifest
      include JSON::Serializable

      getter name : String              # filter name, e.g. "amber"
      getter version : String           # semver of THIS filter
      getter base_model : String        # model id the adapter was trained on
      getter base_filter : String?      # "crystal@0.1.0" when fused-forward atop another filter
      getter library : String?          # the library/artifact this filter teaches
      getter library_version : String?  # which version of that library
      getter lora : LoRASpec
      getter provenance : Provenance
      getter weights_checksum : String  # AdapterArtifact.checksum of the packaged weights
      getter metrics : Hash(String, Float64)

      def initialize(
        @name : String,
        @version : String,
        @base_model : String,
        @lora : LoRASpec,
        @provenance : Provenance,
        @weights_checksum : String,
        @base_filter : String? = nil,
        @library : String? = nil,
        @library_version : String? = nil,
        @metrics : Hash(String, Float64) = {} of String => Float64,
      )
      end

      # "name@version" — the canonical id used in base_filter chains and traces.
      def id : String
        "#{name}@#{version}"
      end
    end

    getter manifest : Manifest
    getter path : Path

    def initialize(@manifest : Manifest, @path : Path)
    end

    # name@version of this filter.
    def id : String
      @manifest.id
    end

    delegate name, version, base_model, base_filter, library, library_version, to: @manifest

    # Package a trained adapter directory into a distributable filter at `dest`.
    # Copies the weights and `adapter_config.json`, stamps the content checksum,
    # and writes the manifest. Returns the loaded TrainingFilter.
    def self.pack(
      adapter_dir : Path | String,
      dest : Path | String,
      name : String,
      version : String,
      base_model : String,
      lora : LoRASpec,
      provenance : Provenance,
      base_filter : String? = nil,
      library : String? = nil,
      library_version : String? = nil,
      metrics : Hash(String, Float64) = {} of String => Float64,
    ) : TrainingFilter
      src = Path[adapter_dir].expand
      raise ArgumentError.new("Adapter directory does not exist: #{src}") unless Dir.exists?(src)
      weights = AdapterArtifact.weight_files(src)
      raise ArgumentError.new("Adapter directory #{src} has no .safetensors weights") if weights.empty?

      pkg = Path[dest].expand
      Dir.mkdir_p(pkg)

      # Copy weights + config into the package.
      weights.each { |w| File.copy(w, pkg.join(File.basename(w))) }
      config = src.join("adapter_config.json")
      File.copy(config, pkg.join("adapter_config.json")) if File.exists?(config)

      manifest = Manifest.new(
        name: name,
        version: version,
        base_model: base_model,
        lora: lora,
        provenance: provenance,
        weights_checksum: AdapterArtifact.checksum(pkg),
        base_filter: base_filter,
        library: library,
        library_version: library_version,
        metrics: metrics,
      )
      File.write(pkg.join(MANIFEST_FILE), manifest.to_pretty_json)
      new(manifest, pkg)
    end

    # Load a filter package, verifying the on-disk weights match the manifest's
    # checksum (integrity / tamper check). Raises on a missing manifest or a
    # checksum mismatch.
    def self.load(dir : Path | String, verify : Bool = true) : TrainingFilter
      pkg = Path[dir].expand
      manifest_path = pkg.join(MANIFEST_FILE)
      unless File.exists?(manifest_path)
        raise ArgumentError.new("Not a training filter package (no #{MANIFEST_FILE}): #{pkg}")
      end
      manifest = Manifest.from_json(File.read(manifest_path))

      if verify
        actual = AdapterArtifact.checksum(pkg)
        if actual != manifest.weights_checksum
          raise TrainingFilterError.new(
            "Checksum mismatch for #{manifest.id}: manifest #{manifest.weights_checksum}, on-disk #{actual}")
        end
      end
      new(manifest, pkg)
    end

    # True iff a directory looks like a training filter package.
    def self.package?(dir : Path | String) : Bool
      File.exists?(Path[dir].expand.join(MANIFEST_FILE))
    end

    # Does this filter target the given base? A filter is compatible when its
    # `base_model` matches and, if it was fused-forward atop another filter, the
    # active `base_filter` id matches what's already composed into the base.
    def compatible_with?(base_model : String, base_filter : String? = nil) : Bool
      return false unless @manifest.base_model == base_model
      @manifest.base_filter.nil? || @manifest.base_filter == base_filter
    end

    # All filter packages installed under `dir` (defaults to the configured
    # filters directory) that are compatible with `base_model`. Packages that
    # fail to load or verify are skipped silently — discovery never raises.
    def self.installed(
      base_model : String,
      base_filter : String? = nil,
      dir : Path | String = Llamero::Storage.filters_dir,
    ) : Array(TrainingFilter)
      all(dir).select(&.compatible_with?(base_model, base_filter))
    end

    # Every loadable filter package under `dir` (one level deep), regardless of
    # compatibility. Unreadable/corrupt packages are skipped.
    def self.all(dir : Path | String = Llamero::Storage.filters_dir) : Array(TrainingFilter)
      base = Path[dir].expand
      return [] of TrainingFilter unless Dir.exists?(base)
      filters = [] of TrainingFilter
      Dir.glob(base.join("*", MANIFEST_FILE).to_s).sort.each do |m|
        begin
          filters << load(Path[m].parent)
        rescue
          # Skip corrupt/incompatible packages; discovery is best-effort.
        end
      end
      filters
    end

    # Filters whose `library` matches a dependency named in a shard.yml, and that
    # fit the given base. The consumer story: "for the libraries this project
    # depends on, which working-knowledge filters can I load?"
    def self.for_shard(
      shard_yml : Path | String,
      base_model : String,
      base_filter : String? = nil,
      dir : Path | String = Llamero::Storage.filters_dir,
    ) : Array(TrainingFilter)
      deps = shard_dependencies(shard_yml)
      installed(base_model, base_filter, dir).select do |f|
        library_name = f.library
        !library_name.nil? && deps.includes?(library_name)
      end
    end

    # Dependency names declared under `dependencies:`/`development_dependencies:`
    # in a shard.yml. A deliberately light parse (top-level keys of those maps)
    # so discovery needs no YAML-schema coupling.
    def self.shard_dependencies(shard_yml : Path | String) : Array(String)
      path = Path[shard_yml].expand
      return [] of String unless File.exists?(path)
      names = [] of String
      in_deps = false
      File.each_line(path) do |line|
        stripped = line.lstrip
        next if stripped.empty? || stripped.starts_with?('#')
        indent = line.size - stripped.size
        if indent == 0
          in_deps = stripped.starts_with?("dependencies:") || stripped.starts_with?("development_dependencies:")
        elsif in_deps && indent == 2 && stripped.includes?(':')
          names << stripped.split(':', 2).first.strip
        end
      end
      names.uniq
    end
  end
end
