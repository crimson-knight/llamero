require "option_parser"
require "./doc_corpus"
require "./training_filter"

module Llamero::Native
  # The `crystal training` subcommand prototype (Phase D). It turns a project's
  # own documentation into training data and, optionally, a distributable
  # training filter — the doc -> data -> adapter pipeline as a first-class tool.
  #
  # This is the logic intended to be grafted into an Agency Crystal compiler fork
  # (extending `Crystal::Doc`), so every project gets it for free. Here it shells
  # `crystal docs --format=json` rather than linking the compiler; the boundary
  # is identical — walk the documented API, emit a kind-tagged corpus, train.
  #
  # Subcommands:
  #   extract  walk docs -> a kind-tagged JSONL corpus (no model needed)
  #   adapter  extract -> unsupervised + SFT via StagedPipeline -> pack a .filter
  #
  # ```text
  # crystal-training extract --shard . --out corpus.jsonl --kind pair
  # crystal-training extract --markdown docs/ --out amber.jsonl
  # crystal-training adapter --markdown docs/ --model mlx-community/gemma-3-1b-it-4bit \
  #     --name amber --library amber --ship dist/amber.filter
  # ```
  module CrystalTraining
    VERSION = "0.1"

    # Build a DocExtractor from a shard directory (runs `crystal docs`) or from
    # markdown (a file, or a directory scanned recursively for *.md / *.markdown).
    def self.extractor_for(shard : String?, markdown : String?, project_name : String, project_version : String) : DocExtractor
      if md = markdown
        DocExtractor.from_markdown(markdown_files(md))
      elsif dir = shard
        DocExtractor.from_shard(dir, project_name: project_name, project_version: project_version)
      else
        raise ArgumentError.new("provide --shard DIR or --markdown PATH")
      end
    end

    # Resolve a markdown path argument to a list of files (a single file, or every
    # *.md/*.markdown under a directory).
    def self.markdown_files(path : String) : Array(String)
      p = Path[path].expand
      if File.directory?(p)
        files = Dir.glob(p.join("**", "*.md").to_s) + Dir.glob(p.join("**", "*.markdown").to_s)
        raise ArgumentError.new("no markdown files under #{p}") if files.empty?
        files.sort
      elsif File.exists?(p)
        [p.to_s]
      else
        raise ArgumentError.new("markdown path not found: #{p}")
      end
    end

    # CLI entry point. Returns a process exit code.
    def self.run(argv : Array(String), io : IO = STDOUT, err : IO = STDERR) : Int32
      sub = argv.first?
      case sub
      when "extract" then run_extract(argv[1..], io, err)
      when "adapter" then run_adapter(argv[1..], io, err)
      when "help", "--help", "-h", nil
        io.puts usage
        0
      else
        err.puts "unknown subcommand: #{sub}"
        err.puts usage
        1
      end
    rescue ex : ArgumentError | TrainingFilterError
      err.puts "error: #{ex.message}"
      1
    end

    def self.usage : String
      <<-USAGE
      crystal-training #{VERSION} — doc -> data -> adapter pipeline

      USAGE:
        crystal-training extract (--shard DIR | --markdown PATH) [options]
        crystal-training adapter (--shard DIR | --markdown PATH) --model ID [options]

      extract options:
        --out PATH          corpus output path (default: stdout)
        --kind pair|text    SFT pairs or unsupervised text (default: pair)
        --all-languages     keep non-Crystal fences too (default: Crystal only)

      adapter options (in addition to a source):
        --model ID          base model id to train on (required)
        --name NAME         filter/adapter name (default: the project/dir name)
        --filter-version V  filter semver (default: 0.1.0)
        --library LIB       the library this filter teaches
        --library-version V the library's version
        --ship PATH         pack a distributable .filter at PATH
        --iters-unsup N     unsupervised iterations (default: 80)
        --iters-sft N       SFT iterations (default: 150)

      common:
        --project-name N    crystal docs project name (default: doc)
        --project-version V crystal docs project version (default: 0.0)
      USAGE
    end

    private def self.run_extract(args : Array(String), io : IO, err : IO) : Int32
      shard = nil.as(String?)
      markdown = nil.as(String?)
      out = nil.as(String?)
      kind = "pair"
      crystal_only = true
      project_name = "doc"
      project_version = "0.0"

      parser = OptionParser.new do |p|
        p.on("--shard DIR", "shard directory (runs crystal docs)") { |v| shard = v }
        p.on("--markdown PATH", "markdown file or directory") { |v| markdown = v }
        p.on("--out PATH", "corpus output path") { |v| out = v }
        p.on("--kind KIND", "pair|text") { |v| kind = v }
        p.on("--all-languages", "keep non-Crystal fences") { crystal_only = false }
        p.on("--project-name N", "") { |v| project_name = v }
        p.on("--project-version V", "") { |v| project_version = v }
      end
      parser.parse(args)

      kind_sym = case kind
                 when "pair" then :pair
                 when "text" then :text
                 else             raise ArgumentError.new("--kind must be pair or text")
                 end

      extractor = extractor_for(shard, markdown, project_name, project_version)
      examples = crystal_only ? extractor.crystal_examples : extractor.examples

      if dest = out
        count = extractor.write_corpus_jsonl(dest, kind: kind_sym, crystal_only: crystal_only)
        io.puts "extracted #{count} #{kind} examples -> #{dest}"
      else
        examples.each do |ex|
          line = kind_sym == :pair ? {kind: "pair", prompt: ex.context, completion: ex.code} : {kind: "text", text: ex.to_text}
          io.puts line.to_json
        end
      end
      0
    end

    private def self.run_adapter(args : Array(String), io : IO, err : IO) : Int32
      shard = nil.as(String?)
      markdown = nil.as(String?)
      model = nil.as(String?)
      name = nil.as(String?)
      filter_version = "0.1.0"
      library = nil.as(String?)
      library_version = nil.as(String?)
      ship = nil.as(String?)
      iters_unsup = 80
      iters_sft = 150
      project_name = "doc"
      project_version = "0.0"

      parser = OptionParser.new do |p|
        p.on("--shard DIR", "") { |v| shard = v }
        p.on("--markdown PATH", "") { |v| markdown = v }
        p.on("--model ID", "base model id") { |v| model = v }
        p.on("--name NAME", "") { |v| name = v }
        p.on("--filter-version V", "") { |v| filter_version = v }
        p.on("--library LIB", "") { |v| library = v }
        p.on("--library-version V", "") { |v| library_version = v }
        p.on("--ship PATH", "pack a .filter here") { |v| ship = v }
        p.on("--iters-unsup N", "") { |v| iters_unsup = v.to_i }
        p.on("--iters-sft N", "") { |v| iters_sft = v.to_i }
        p.on("--project-name N", "") { |v| project_name = v }
        p.on("--project-version V", "") { |v| project_version = v }
      end
      parser.parse(args)

      # Copy closure-captured vars to plain locals so `||` type-narrows.
      model_value = model
      name_value = name
      model_id = model_value || raise ArgumentError.new("--model is required for adapter")
      filter_name = name_value || default_name(shard, markdown)

      extractor = extractor_for(shard, markdown, project_name, project_version)
      pairs = extractor.to_supervised_dataset(crystal_only: true)
      text = extractor.to_unsupervised_dataset(crystal_only: true)
      examples = extractor.crystal_examples
      raise ArgumentError.new("no Crystal examples found in the docs") if examples.empty?
      io.puts "extracted #{examples.size} Crystal examples; training '#{filter_name}' on #{model_id}"

      bridge = MLXBridge.try_load
      unless bridge
        err.puts "no MLX bridge available — build native/llamero-mlx (./build.sh) to train"
        return 2
      end
      runtime = MLXRuntime.new(model_id: model_id, bridge: bridge)
      session = runtime.start_session
      session.load_model

      pipeline = StagedPipeline.new(session, filter_name)
      pipeline.unsupervised("facts", text, config_with(iters_unsup))
      pipeline.supervised("usage", pairs, config_with(iters_sft))
      results = pipeline.run { |i, stage| io.puts "  stage #{i}: #{stage}" }
      descriptor = results.last.descriptor

      descriptor_path = descriptor.path
      if dest = ship
        filter = TrainingFilter.pack(
          adapter_dir: descriptor_path, dest: dest,
          name: filter_name, version: filter_version, base_model: model_id,
          lora: TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 8),
          provenance: TrainingFilter::Provenance.new(methods: ["unsupervised", "sft"], generator: "crystal-training/#{VERSION}"),
          library: library, library_version: library_version,
        )
        io.puts "packed #{filter.id} -> #{dest}"
      else
        io.puts "trained adapter -> #{descriptor_path} (use --ship to package a .filter)"
      end
      runtime.close
      0
    end

    private def self.config_with(iters : Int32) : AdapterTrainingConfig
      c = AdapterTrainingConfig.new
      c.iterations = iters
      c.num_layers = 8
      c.batch_size = 1
      c.learning_rate = 1e-4
      c.steps_per_report = 1000
      c
    end

    private def self.default_name(shard : String?, markdown : String?) : String
      raw = shard || markdown || "adapter"
      base = File.basename(Path[raw].expand.to_s)
      base.empty? ? "adapter" : base
    end
  end
end
