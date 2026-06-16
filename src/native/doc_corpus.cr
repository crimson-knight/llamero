require "json"

module Llamero::Native
  # One training example extracted from documentation: a code block plus the
  # context that explains it. Pulled deterministically from real, authored docs
  # (no model, no hallucination) — either Crystal API docs (`crystal docs
  # --format=json`) or standalone markdown pages such as an Amber controller
  # guide.
  struct DocExample
    getter source : String    # full_name (API) or file path (markdown)
    getter context : String   # signature + prose describing the code
    getter code : String      # the fenced code block, verbatim
    getter language : String  # fence language; "" is normalized to "crystal"

    def initialize(@source : String, @context : String, @code : String, @language : String = "crystal")
    end

    # Supervised pair: "this API and what it does" -> "valid usage of it".
    def to_pair : {String, String}
      {context, code}
    end

    # Unsupervised chunk: the context and example as one verbatim block.
    def to_text : String
      context.empty? ? code : "#{context}\n\n#{code}"
    end
  end

  # Extracts code examples from documentation into training data. Two sources,
  # both deterministic and valid-by-authorship:
  #   - Crystal API docs JSON (doc comments on every type and member), via
  #     `from_docs_json` / `from_shard`.
  #   - Standalone markdown pages (guides/tutorials), via `from_markdown`.
  # Feeds the training methods through `to_supervised_dataset` /
  # `to_unsupervised_dataset` or a kind-tagged JSONL corpus.
  class DocExtractor
    getter examples = [] of DocExample

    MEMBER_KEYS = %w(constructors class_methods instance_methods macros constants)

    # Ingest the JSON emitted by `crystal docs --format=json`.
    def self.from_docs_json(json : String) : DocExtractor
      extractor = new
      extractor.ingest_docs_json(JSON.parse(json))
      extractor
    end

    # Run `crystal docs --format=json` in a shard directory and ingest it.
    def self.from_shard(
      shard_dir : Path | String,
      project_name : String = "doc",
      project_version : String = "0.0"
    ) : DocExtractor
      dir = Path[shard_dir].expand
      output = IO::Memory.new
      status = Process.run(
        "crystal",
        ["docs", "--format=json", "--project-name=#{project_name}", "--project-version=#{project_version}"],
        chdir: dir.to_s, output: output, error: Process::Redirect::Close
      )
      raise "crystal docs --format=json failed in #{dir}" unless status.success?
      from_docs_json(output.to_s)
    end

    # Extract code blocks from one or more standalone markdown documents.
    def self.from_markdown(paths : Array(String) | Array(Path)) : DocExtractor
      extractor = new
      paths.each do |p|
        file = Path[p].expand
        raise ArgumentError.new("Markdown not found: #{file}") unless File.exists?(file)
        extractor.ingest_markdown(File.read(file.to_s), source: file.to_s)
      end
      extractor
    end

    def ingest_docs_json(root : JSON::Any) : Nil
      program = root["program"]?
      walk_type(program) if program
    end

    # Walk the recursive type tree, pulling code blocks from every type's and
    # member's doc comment, tagged with the symbol's signature as context.
    private def walk_type(type : JSON::Any) : Nil
      full = type["full_name"]?.try(&.as_s?) || type["name"]?.try(&.as_s?) || "?"

      if doc = type["doc"]?.try(&.as_s?)
        add_from_doc(source: full, signature: full, doc: doc)
      end

      MEMBER_KEYS.each do |key|
        type[key]?.try(&.as_a?).try &.each do |member|
          name = member["name"]?.try(&.as_s?) || ""
          args = member["args_string"]?.try(&.as_s?) || ""
          sig = "#{full}##{name}#{args}"
          if doc = member["doc"]?.try(&.as_s?)
            add_from_doc(source: sig, signature: sig, doc: doc)
          end
        end
      end

      type["types"]?.try(&.as_a?).try &.each { |sub| walk_type(sub) }
    end

    private def add_from_doc(source : String, signature : String, doc : String) : Nil
      blocks = fenced_blocks(doc)
      return if blocks.empty?
      prose = strip_fences(doc).strip.gsub(/\s+/, " ")
      blocks.each do |lang, code|
        next if code.empty?
        context = prose.empty? ? signature : "#{signature} — #{prose}"
        @examples << DocExample.new(source: source, context: context, code: code, language: normalize_lang(lang))
      end
    end

    # Parse a standalone markdown doc, pairing each code block with the nearest
    # heading and preceding prose as its context.
    def ingest_markdown(markdown : String, source : String) : Nil
      lines = markdown.split('\n')
      heading = ""
      prose = [] of String
      i = 0
      while i < lines.size
        line = lines[i]
        if line.starts_with?('#')
          heading = line.lstrip('#').strip
          prose.clear
        elsif fence_open?(line)
          lang = fence_lang(line)
          code = [] of String
          i += 1
          while i < lines.size && !fence_close?(lines[i])
            code << lines[i]
            i += 1
          end
          body = code.join('\n').strip
          unless body.empty?
            recent = prose.reject(&.strip.empty?).last(2).join(" ").strip
            context = [heading, recent].reject(&.empty?).join(": ")
            @examples << DocExample.new(source: source, context: context, code: body, language: normalize_lang(lang))
          end
          prose.clear
        else
          # Strip gitbook/jekyll liquid tags ({% ... %}, {{ ... }}) from prose so
          # the context isn't polluted with templating noise.
          prose << line.gsub(/\{%.*?%\}/, "").gsub(/\{\{.*?\}\}/, "")
        end
        i += 1
      end
    end

    # ---- supervised / unsupervised / corpus outputs ----

    # Only the Crystal code examples (drops shell/yaml/etc. fences).
    def crystal_examples : Array(DocExample)
      @examples.select { |ex| ex.language == "crystal" }
    end

    # Supervised dataset of (context -> code) pairs.
    def to_supervised_dataset(crystal_only : Bool = true) : TrainingDataset
      ds = TrainingDataset.new
      (crystal_only ? crystal_examples : @examples).each { |ex| ds.add(ex.context, ex.code) }
      ds
    end

    # Unsupervised dataset of verbatim "context + code" chunks.
    def to_unsupervised_dataset(crystal_only : Bool = true) : TrainingDataset
      TrainingDataset.from_text((crystal_only ? crystal_examples : @examples).map(&.to_text))
    end

    # Write a kind-tagged JSONL corpus (the consistent multi-method format).
    # `kind` is :pair (SFT) or :text (unsupervised).
    def write_corpus_jsonl(path : Path | String, kind : Symbol = :pair, crystal_only : Bool = true) : Int32
      list = crystal_only ? crystal_examples : @examples
      File.open(Path[path].expand.to_s, "w") do |file|
        list.each do |ex|
          case kind
          when :pair then file.puts({kind: "pair", prompt: ex.context, completion: ex.code}.to_json)
          when :text then file.puts({kind: "text", text: ex.to_text}.to_json)
          else            raise ArgumentError.new("kind must be :pair or :text")
          end
        end
      end
      list.size
    end

    # ---- markdown fence helpers ----

    private def fenced_blocks(doc : String) : Array({String, String})
      blocks = [] of {String, String}
      lines = doc.split('\n')
      i = 0
      while i < lines.size
        if fence_open?(lines[i])
          lang = fence_lang(lines[i])
          code = [] of String
          i += 1
          while i < lines.size && !fence_close?(lines[i])
            code << lines[i]
            i += 1
          end
          blocks << {lang, code.join('\n').strip}
        end
        i += 1
      end
      blocks
    end

    private def strip_fences(doc : String) : String
      out = [] of String
      lines = doc.split('\n')
      i = 0
      while i < lines.size
        if fence_open?(lines[i])
          i += 1
          while i < lines.size && !fence_close?(lines[i])
            i += 1
          end
        else
          out << lines[i]
        end
        i += 1
      end
      out.join('\n')
    end

    private def fence_open?(line : String) : Bool
      line.lstrip.starts_with?("```")
    end

    private def fence_close?(line : String) : Bool
      line.lstrip.rstrip == "```"
    end

    private def fence_lang(line : String) : String
      line.lstrip.lchop("```").strip
    end

    # Crystal-ecosystem docs commonly fence Crystal as ```ruby (for syntax
    # highlighting) or with a bare fence. Treat those as Crystal so the corpus
    # isn't dominated by mislabeled examples.
    CRYSTAL_FENCE_ALIASES = {"", "crystal", "cr", "ruby", "rb"}

    private def normalize_lang(lang : String) : String
      normalized = lang.downcase.strip
      CRYSTAL_FENCE_ALIASES.includes?(normalized) ? "crystal" : normalized
    end
  end

  # Generates valid code examples by mixing and matching documented chunks into
  # a template. Every combination is valid by construction — the chunks and the
  # template are valid, so the output is too. `combo` is the breadth knob (mix
  # and match subsets of chunks); `constrain` prunes combinations that wouldn't
  # be valid; `verified` compile-checks the output as a safety net. The goal is
  # to turn a handful of building blocks into the full space of valid usage.
  #
  # ```
  # gen = ExampleGenerator.new("class {{name}}Controller\n{{actions}}\nend")
  # gen.slot("name", ["Users", "Posts"])
  # gen.combo("actions", ["def index; end", "def show; end"], min: 1)
  # gen.to_a # => every valid controller over those choices
  # ```
  class ExampleGenerator
    record Slot, name : String, options : Array(String)

    @slots = [] of Slot
    @constraints = [] of Hash(String, String) -> Bool

    def initialize(@template : String)
    end

    # A slot filled by exactly one of `options` per example.
    def slot(name : String, options : Array(String)) : self
      @slots << Slot.new(name, options)
      self
    end

    # A slot filled by mixing and matching a SUBSET of `chunks` (subset size in
    # min..max), joined by `join`. This produces the mix-and-match breadth.
    def combo(
      name : String, chunks : Array(String),
      min : Int32 = 1, max : Int32? = nil, join : String = "\n\n"
    ) : self
      hi = max || chunks.size
      options = [] of String
      (min..hi).each do |k|
        chunks.each_combination(k) { |c| options << c.join(join) }
      end
      slot(name, options)
    end

    # Reject a selection (slot name => chosen value) that isn't valid.
    def constrain(&block : Hash(String, String) -> Bool) : self
      @constraints << block
      self
    end

    # Render every valid combination of the slots into the template.
    def each(& : String ->) : Nil
      selections.each do |selection|
        next unless @constraints.all?(&.call(selection))
        yield render(selection)
      end
    end

    def to_a : Array(String)
      out = [] of String
      each { |code| out << code }
      out
    end

    # Build a supervised dataset where each generated example is a completion
    # for the same `prompt` (e.g. "Write a valid Amber controller").
    def to_supervised_dataset(prompt : String) : TrainingDataset
      ds = TrainingDataset.new
      each { |code| ds.add(prompt, code) }
      ds
    end

    # Keep only examples that compile once wrapped into a full program by
    # `wrap` (which prepends any DSL/stub needed). Compile-verification of the
    # generated, valid-by-construction examples — a safety net for the grammar.
    def verified(& wrap : String -> String) : Array(String)
      to_a.select { |code| ExampleGenerator.compiles?(wrap.call(code)) }
    end

    # True if `program` type-checks (`crystal build --no-codegen`).
    def self.compiles?(program : String) : Bool
      file = File.tempfile("genex", ".cr") { |f| f.print(program) }
      begin
        Process.run(
          "crystal", ["build", "--no-codegen", file.path],
          output: Process::Redirect::Close, error: Process::Redirect::Close
        ).success?
      ensure
        file.delete
      end
    end

    private def render(selection : Hash(String, String)) : String
      result = @template
      selection.each { |name, value| result = result.gsub("{{#{name}}}", value) }
      result
    end

    # Iterative cartesian product of the slots' options -> one selection map per
    # combination (kept non-recursive; Crystal can't inline a recursive yield).
    private def selections : Array(Hash(String, String))
      result = [{} of String => String]
      @slots.each do |slot|
        expanded = [] of Hash(String, String)
        result.each do |partial|
          slot.options.each do |opt|
            merged = partial.dup
            merged[slot.name] = opt
            expanded << merged
          end
        end
        result = expanded
      end
      result
    end
  end
end
