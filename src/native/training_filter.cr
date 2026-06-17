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
      getter weights_checksum : String  # checksum of the packaged weights (single or chain)
      getter metrics : Hash(String, Float64)
      # Ordered stage subdirectories for a fuse-forward CHAIN. Empty for a plain
      # single-adapter filter (weights at the package root). When non-empty, each
      # entry is a subdir holding one stage's adapter, applied in order: the
      # consumer reloads the base and fuses each forward to reconstruct the exact
      # composition the publisher built (a multi-stage composition is a mutated
      # base, not a single LoRA delta, so it can't ship as one root adapter).
      getter stages : Array(String)

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
        @stages : Array(String) = [] of String,
      )
      end

      # "name@version" — the canonical id used in base_filter chains and traces.
      def id : String
        "#{name}@#{version}"
      end

      # True when this filter is a fuse-forward chain of stage adapters.
      def chain? : Bool
        !@stages.empty?
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
        weights_checksum: package_checksum(pkg, [] of String),
        base_filter: base_filter,
        library: library,
        library_version: library_version,
        metrics: metrics,
      )
      File.write(pkg.join(MANIFEST_FILE), manifest.to_pretty_json)
      new(manifest, pkg)
    end

    # Package an ordered fuse-forward CHAIN of stage adapters into one filter. The
    # consumer reloads the base and fuses each stage forward in order to
    # reconstruct the exact composition — the only correct way to ship a
    # multi-stage composition, since each later stage's delta is relative to the
    # base with the earlier stages already fused in (not the bare base).
    def self.pack_chain(
      adapter_dirs : Array(Path) | Array(String),
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
      raise ArgumentError.new("pack_chain needs at least one adapter") if adapter_dirs.empty?
      pkg = Path[dest].expand
      Dir.mkdir_p(pkg)

      stages = [] of String
      adapter_dirs.each_with_index do |dir, i|
        src = Path[dir].expand
        raise ArgumentError.new("Adapter directory does not exist: #{src}") unless Dir.exists?(src)
        weights = AdapterArtifact.weight_files(src)
        raise ArgumentError.new("Adapter directory #{src} has no .safetensors weights") if weights.empty?
        sub = "stage-#{i}"
        stage_out = pkg.join(sub)
        Dir.mkdir_p(stage_out)
        weights.each { |w| File.copy(w, stage_out.join(File.basename(w))) }
        config = src.join("adapter_config.json")
        File.copy(config, stage_out.join("adapter_config.json")) if File.exists?(config)
        stages << sub
      end

      manifest = Manifest.new(
        name: name,
        version: version,
        base_model: base_model,
        lora: lora,
        provenance: provenance,
        weights_checksum: package_checksum(pkg, stages),
        base_filter: base_filter,
        library: library,
        library_version: library_version,
        metrics: metrics,
        stages: stages,
      )
      File.write(pkg.join(MANIFEST_FILE), manifest.to_pretty_json)
      new(manifest, pkg)
    end

    # Content checksum over a package: the root adapter for a single filter, or
    # every stage subdir in order for a chain. One source of truth for pack+load.
    def self.package_checksum(pkg : Path, stages : Array(String)) : String
      return AdapterArtifact.checksum(pkg) if stages.empty?
      digest = Digest::SHA256.new
      stages.each do |s|
        digest.update(s)
        digest.update(AdapterArtifact.checksum(pkg.join(s)))
      end
      digest.final.hexstring[0, 16]
    end

    # Absolute paths to the stage adapter dirs, in fuse order (empty for a single
    # filter — its weights live at the package root).
    def stage_dirs : Array(Path)
      @manifest.stages.map { |s| @path.join(s) }
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
        actual = package_checksum(pkg, manifest.stages)
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
