require "json"
require "file_utils"
require "crinja"
require "./errors"

module Llamero::Native
  # Hyperparameters for training a LoRA/DoRA adapter on the resident model.
  #
  # When the base model is quantized (the normal case for on-device models
  # like `*-4bit`), training automatically uses QLoRA-style adapters over the
  # quantized layers - no separate mode is needed.
  #
  # The defaults are sized for small on-device fine-tunes (teach the model a
  # manual, a tone, a domain vocabulary), not for full-scale instruction
  # tuning.
  struct AdapterTrainingConfig
    include JSON::Serializable

    enum FineTuneType
      Lora
      Dora
    end

    # LoRA rank: capacity of the adapter. 8 is plenty for fact/style tuning.
    property rank : Int32 = 8

    # LoRA alpha-style scale baked into the trained adapter
    # (mlx_lm convention; distinct from runtime AdapterSlot scale).
    property scale : Float64 = 10.0

    # How many of the model's final transformer layers get adapters.
    property num_layers : Int32 = 16

    property fine_tune_type : FineTuneType = FineTuneType::Lora

    # Total optimizer steps.
    property iterations : Int32 = 200

    # Examples per step. Keep small on-device; memory grows with batch size
    # and sequence length.
    property batch_size : Int32 = 2

    property learning_rate : Float64 = 1e-5

    # Emit a TrainingProgressEvent every N steps.
    property steps_per_report : Int32 = 10

    # Run validation (TrainingValidationEvent) every N steps.
    property steps_per_eval : Int32 = 50

    # Validation batches per eval pass (0 = the full validation set).
    property validation_batches : Int32 = 5

    # Training objective: :sft (default), :dpo (preference optimization), or
    # :weighted (advantage-weighted / GRPO policy update). Usually inferred from
    # the dataset type by `train_adapter`.
    property training_method : Symbol = :sft

    # DPO temperature / KL strength. Only used when training_method is :dpo.
    property dpo_beta : Float64 = 0.1

    # KL-to-reference penalty strength for :weighted (GRPO). Anchors the policy to
    # the frozen base so multi-round updates don't diverge. 0 disables the anchor.
    property kl_beta : Float64 = 0.05

    def initialize
    end

    def validate! : Nil
      raise ArgumentError.new("rank must be positive") unless @rank > 0
      raise ArgumentError.new("num_layers must be positive") unless @num_layers > 0
      raise ArgumentError.new("iterations must be positive") unless @iterations > 0
      raise ArgumentError.new("batch_size must be positive") unless @batch_size > 0
      raise ArgumentError.new("learning_rate must be positive and finite") unless @learning_rate > 0 && @learning_rate.finite?
    end
  end

  # A golden dataset of prompt/completion pairs for adapter training.
  #
  # Pairs are rendered through a chat template into the plain-text training
  # format mlx_lm uses (`{"text": "..."}` JSONL), split into train/valid
  # files. When a dataset with the default format reaches
  # ModelSession#train_adapter, the session swaps in the model's own chat
  # template (see `.template_from`) when the model directory is available
  # locally, falling back to the built-ins. Pass a custom `format` proc to
  # override the rendering entirely.
  #
  # ```crystal
  # dataset = Llamero::Native::TrainingDataset.new(
  #   system_prompt: "You are a bulldozer maintenance expert."
  # )
  # dataset.add(
  #   "What are the fuel injector specs for the LX-900?",
  #   "The LX-900 uses BR-7741 injectors at 2,150 PSI with a 4-hole nozzle."
  # )
  # data_dir = dataset.write(Path["training/lx900"])
  # ```
  class TrainingDataset
    record Pair, prompt : String, completion : String

    # ChatML rendering (Qwen, and many instruct models).
    CHATML = ->(pair : Pair, system_prompt : String?) : String {
      String.build do |text|
        if system_prompt
          text << "<|im_start|>system\n" << system_prompt << "<|im_end|>\n"
        end
        text << "<|im_start|>user\n" << pair.prompt << "<|im_end|>\n"
        text << "<|im_start|>assistant\n" << pair.completion << "<|im_end|>"
      end
    }

    # Gemma turn rendering. Gemma has no system role; the system prompt is
    # folded into the first user turn, matching the reference chat template.
    GEMMA = ->(pair : Pair, system_prompt : String?) : String {
      String.build do |text|
        text << "<start_of_turn>user\n"
        if system_prompt
          text << system_prompt << "\n\n"
        end
        text << pair.prompt << "<end_of_turn>\n"
        text << "<start_of_turn>model\n" << pair.completion << "<end_of_turn>"
      end
    }

    # Picks the chat template that matches a model id, so datasets render
    # with the special tokens the model was instruction-tuned on. Training
    # with the wrong template still converges but the adapter answers
    # poorly at inference time.
    def self.template_for(model_id : String) : Proc(Pair, String?, String)
      model_id.downcase.includes?("gemma") ? GEMMA : CHATML
    end

    # Builds a rendering proc from the model's own chat template, read from
    # the downloaded model directory (`tokenizer_config.json` key
    # "chat_template", else `chat_template.jinja`, else `chat_template.json`).
    #
    # This is the most faithful option: it renders training data with exactly
    # the Jinja template the Swift bridge uses at inference time, so train
    # and inference formatting can never drift apart.
    #
    # Returns nil - never raises - when no template ships with the model or
    # when crinja cannot parse/render it (HuggingFace templates lean on
    # python-isms like `messages[1:]` slicing or `.strip()` method calls that
    # a Jinja engine does not implement). Callers fall back to the built-in
    # `template_for` templates.
    def self.template_from(model_dir : Path | String) : Proc(Pair, String?, String)?
      dir = Path[model_dir].expand
      source = chat_template_source(dir)
      return nil unless source

      bos_token, eos_token = special_tokens(dir)

      env = Crinja.new
      env.functions["raise_exception"] = Crinja.function({message: ""}) do
        raise Crinja::RuntimeError.new(arguments["message"].to_s)
      end
      template = env.from_string(source)

      format = ->(pair : Pair, system_prompt : String?) : String {
        messages = [] of Hash(String, String)
        if system = system_prompt
          messages << {"role" => "system", "content" => system}
        end
        messages << {"role" => "user", "content" => pair.prompt}
        messages << {"role" => "assistant", "content" => pair.completion}

        template.render({
          "messages"              => messages,
          "add_generation_prompt" => false,
          "bos_token"             => bos_token,
          "eos_token"             => eos_token,
        })
      }

      # Probe renders (with and without a system turn) so unsupported
      # constructs - or templates that raise_exception on system roles -
      # surface here instead of crashing dataset writes later.
      probe = Pair.new("probe prompt", "probe completion")
      format.call(probe, "probe system prompt")
      format.call(probe, nil)
      format
    rescue
      nil
    end

    # Pulls the raw Jinja chat template out of the model directory, checking
    # the locations HuggingFace repos use, most common first.
    private def self.chat_template_source(dir : Path) : String?
      if raw = tokenizer_config_values(dir, ["chat_template"])["chat_template"]?
        if source = raw.as_s?
          return source
        end
        # Rare list form: [{"name": "default", "template": "..."}, ...]
        if list = raw.as_a?
          entry = list.find { |item| item.as_h?.try(&.["name"]?).try(&.as_s?) == "default" } || list.first?
          if source = entry.try(&.as_h?).try(&.["template"]?).try(&.as_s?)
            return source
          end
        end
      end

      jinja_path = dir.join("chat_template.jinja")
      return File.read(jinja_path) if File.exists?(jinja_path)

      json_path = dir.join("chat_template.json")
      if File.exists?(json_path)
        return JSON.parse(File.read(json_path))["chat_template"]?.try(&.as_s?)
      end

      nil
    rescue JSON::ParseException
      nil
    end

    # Reads bos/eos tokens from tokenizer_config.json. Tokens are either
    # plain strings or AddedToken objects with a "content" field.
    private def self.special_tokens(dir : Path) : {String, String}
      tokens = tokenizer_config_values(dir, ["bos_token", "eos_token"])
      {token_content(tokens["bos_token"]?), token_content(tokens["eos_token"]?)}
    end

    # Extracts top-level keys from tokenizer_config.json with a pull parser,
    # skipping everything else. Whole-file JSON.parse is too brittle here:
    # Gemma configs carry a model_max_length larger than Int64, which makes
    # Crystal's JSON.parse reject the entire file and would needlessly lose
    # the chat template.
    private def self.tokenizer_config_values(dir : Path, keys : Array(String)) : Hash(String, JSON::Any)
      values = {} of String => JSON::Any
      config_path = dir.join("tokenizer_config.json")
      return values unless File.exists?(config_path)

      pull = JSON::PullParser.new(File.read(config_path))
      pull.read_object do |key|
        if keys.includes?(key)
          values[key] = JSON::Any.new(pull)
        else
          pull.skip
        end
      end
      values
    rescue JSON::ParseException
      # Keep whatever parsed cleanly before the bad value.
      values || {} of String => JSON::Any
    end

    private def self.token_content(value : JSON::Any?) : String
      return "" unless value
      value.as_s? || value.as_h?.try(&.["content"]?).try(&.as_s?) || ""
    end

    getter pairs = [] of Pair
    property system_prompt : String?

    # True when the caller chose the rendering format explicitly (passed
    # `format:`). ModelSession#train_adapter only auto-applies the model's
    # own chat template to datasets that kept the default.
    getter? format_explicit : Bool

    # Which template renders this dataset: "default" (built-in ChatML, never
    # overridden), "explicit" (caller passed `format:`), or - set by
    # ModelSession#train_adapter - "model-chat-template" / "built-in".
    getter template_source : String

    @format : Proc(Pair, String?, String)

    # Raw text chunks for UNSUPERVISED continued pretraining. When present they
    # are trained on verbatim (no chat template) and `@pairs`/`@format` are
    # ignored. Set via `from_text` / `from_documents`.
    @raw_texts : Array(String)?

    def initialize(
      @system_prompt : String? = nil,
      format : Proc(Pair, String?, String)? = nil,
      @raw_texts : Array(String)? = nil
    )
      @format = format || CHATML
      # Raw-text datasets never want a chat template applied, so mark them
      # explicit (ModelSession#train_adapter only auto-templates default ones).
      @format_explicit = !format.nil? || !@raw_texts.nil?
      @template_source = @raw_texts ? "raw-text" : (format ? "explicit" : "default")
    end

    # True for unsupervised continued-pretraining datasets (raw text, no pairs).
    def raw_text? : Bool
      !@raw_texts.nil?
    end

    # Replaces the rendering template without marking it explicit. Used by
    # ModelSession#train_adapter's auto-template path; `source` keeps the
    # choice observable through `template_source`.
    def use_template(format : Proc(Pair, String?, String), source : String) : self
      @format = format
      @template_source = source
      self
    end

    # Loads a dataset from a JSONL file of raw prompt/completion pairs:
    #
    # ```text
    # {"prompt": "What is X?", "completion": "X is ..."}
    # ```
    #
    # Raw pairs stay portable across model families - the chat template is
    # applied at write time, so the same file can train a ChatML model today
    # and a Gemma-template model tomorrow. llamero ships one such file,
    # `training_data/llamero_api_qa.jsonl`, teaching its own API.
    def self.from_pairs_jsonl(
      path : Path | String,
      system_prompt : String? = nil,
      format : Proc(Pair, String?, String)? = nil
    ) : TrainingDataset
      file = Path[path].expand
      raise ArgumentError.new("Pairs file not found: #{file}") unless File.exists?(file)

      dataset = new(system_prompt, format)
      File.each_line(file.to_s) do |line|
        next if line.blank?
        row = JSON.parse(line)
        prompt = row["prompt"]?.try(&.as_s?)
        completion = row["completion"]?.try(&.as_s?)
        unless prompt && completion
          raise ArgumentError.new(
            "Each line needs string \"prompt\" and \"completion\" fields, got: #{line[0, 120]}"
          )
        end
        dataset.add(prompt, completion)
      end
      raise ArgumentError.new("Pairs file #{file} contained no pairs") if dataset.pairs.empty?
      dataset
    end

    def add(prompt : String, completion : String) : self
      raise ArgumentError.new("prompt cannot be blank") if prompt.blank?
      raise ArgumentError.new("completion cannot be blank") if completion.blank?
      @pairs << Pair.new(prompt, completion)
      self
    end

    # Loads a kind-tagged corpus JSONL — the consistent multi-method format
    # emitted by DocExtractor / ExampleGenerator — into a trainable dataset,
    # closing the loop from documentation to training. Each line is
    # `{"kind": …, …}`:
    #
    # ```text
    # {"kind":"text","text":"..."}                       # -> unsupervised chunk
    # {"kind":"pair","prompt":"...","completion":"..."}  # -> supervised pair
    # ```
    #
    # For a homogeneous corpus the dataset type is inferred; pass `only:` to
    # select one kind from a mixed corpus. `preference`/`trajectory` kinds are
    # recognized but not yet trainable as a dataset (DPO/RL land later).
    def self.from_corpus_jsonl(
      path : Path | String,
      only : Symbol? = nil,
      system_prompt : String? = nil,
      format : Proc(Pair, String?, String)? = nil
    ) : TrainingDataset
      file = Path[path].expand
      raise ArgumentError.new("Corpus file not found: #{file}") unless File.exists?(file)

      texts = [] of String
      pairs = [] of Pair
      kinds = [] of String
      File.each_line(file.to_s) do |line|
        next if line.blank?
        row = JSON.parse(line)
        kind = row["kind"]?.try(&.as_s?) || "pair"
        next if only && kind != only.to_s
        kinds << kind unless kinds.includes?(kind)
        case kind
        when "text"
          if t = row["text"]?.try(&.as_s?)
            texts << t unless t.blank?
          end
        when "pair"
          prompt = row["prompt"]?.try(&.as_s?)
          completion = row["completion"]?.try(&.as_s?)
          pairs << Pair.new(prompt, completion) if prompt && completion
        when "preference", "trajectory"
          raise ArgumentError.new("Corpus kind '#{kind}' is recognized but not yet trainable as a dataset (DPO/RL land later); pass only: :text or only: :pair to select what is")
        else
          raise ArgumentError.new("Unknown corpus kind '#{kind}' in #{file}")
        end
      end

      effective = only.try(&.to_s) || (kinds.size == 1 ? kinds.first : nil)
      if effective.nil?
        raise ArgumentError.new("Mixed-kind corpus #{file} (#{kinds.join(", ")}); pass only: :text or only: :pair")
      end

      case effective
      when "text"
        raise ArgumentError.new("No text examples in #{file}") if texts.empty?
        from_text(texts)
      when "pair"
        raise ArgumentError.new("No pair examples in #{file}") if pairs.empty?
        dataset = new(system_prompt, format)
        pairs.each { |p| dataset.add(p.prompt, p.completion) }
        dataset
      else
        raise ArgumentError.new("Cannot build a dataset from corpus kind '#{effective}'")
      end
    end

    # UNSUPERVISED continued-pretraining dataset from raw text chunks. Unlike
    # `from_pairs_jsonl` (supervised prompt/completion), each chunk is trained on
    # verbatim with full-sequence causal-LM loss and NO chat template, so the
    # model absorbs the documentation's facts, vocabulary, and style. This is the
    # "learn the domain" layer; stack supervised pairs (and later preference/RL)
    # on top — fusing each stage's adapter into the base before the next.
    def self.from_text(chunks : Array(String)) : TrainingDataset
      cleaned = chunks.map(&.strip).reject(&.empty?)
      raise ArgumentError.new("from_text needs at least one non-empty chunk") if cleaned.empty?
      new(raw_texts: cleaned)
    end

    # Reads structured-documentation files and chunks them for unsupervised
    # continued pretraining: each file is split on blank lines into paragraph-ish
    # chunks, and chunks under `min_chars` are merged forward so single lines
    # don't dominate. Markdown and plain text both work.
    def self.from_documents(paths : Array(String) | Array(Path), min_chars : Int32 = 200) : TrainingDataset
      chunks = [] of String
      paths.each do |p|
        file = Path[p].expand
        raise ArgumentError.new("Document not found: #{file}") unless File.exists?(file)
        chunks.concat(chunk_text(File.read(file.to_s), min_chars))
      end
      from_text(chunks)
    end

    # Splits text on blank lines, merging paragraphs forward until each chunk is
    # at least `min_chars` so very short lines don't become their own examples.
    private def self.chunk_text(content : String, min_chars : Int32) : Array(String)
      paragraphs = content.split(/\n\s*\n/).map(&.strip).reject(&.empty?)
      chunks = [] of String
      buffer = ""
      paragraphs.each do |para|
        buffer = buffer.empty? ? para : "#{buffer}\n\n#{para}"
        if buffer.size >= min_chars
          chunks << buffer
          buffer = ""
        end
      end
      chunks << buffer unless buffer.strip.empty?
      chunks
    end

    def size : Int32
      @raw_texts.try(&.size) || @pairs.size
    end

    # The plain-text training strings: raw chunks for unsupervised datasets, or
    # chat-template-rendered pairs for supervised ones.
    private def dataset_texts : Array(String)
      if raw = @raw_texts
        raw
      else
        @pairs.map { |pair| @format.call(pair, @system_prompt) }
      end
    end

    # Writes train.jsonl and valid.jsonl into the directory and returns it.
    #
    # The validation split is deterministic (every Nth example) so runs are
    # reproducible; with very small datasets the first example is reused for
    # validation so there is always something to score against.
    def write(directory : Path | String, valid_fraction : Float64 = 0.1) : Path
      texts = dataset_texts
      raise ArgumentError.new("Cannot write an empty training dataset") if texts.empty?
      unless valid_fraction >= 0.0 && valid_fraction < 1.0
        raise ArgumentError.new("valid_fraction must be in [0, 1)")
      end

      dir = Path[directory].expand
      FileUtils.mkdir_p(dir.to_s)

      valid_every = valid_fraction > 0 ? (1.0 / valid_fraction).round.to_i : 0
      train_texts = [] of String
      valid_texts = [] of String
      texts.each_with_index do |text, index|
        if valid_every > 0 && (index + 1) % valid_every == 0
          valid_texts << text
        else
          train_texts << text
        end
      end

      # Never let either split be empty.
      train_texts = texts.dup if train_texts.empty?
      valid_texts << texts.first if valid_texts.empty?

      write_jsonl(dir.join("train.jsonl"), train_texts)
      write_jsonl(dir.join("valid.jsonl"), valid_texts)
      dir
    end

    private def write_jsonl(path : Path, texts : Array(String)) : Nil
      File.open(path.to_s, "w") do |file|
        texts.each do |text|
          file.puts({"text" => text}.to_json)
        end
      end
    end
  end

  # Preference dataset for DPO: (prompt, chosen, rejected) triples. The model is
  # optimized to prefer `chosen` over `rejected` relative to the frozen base.
  # Written as train.jsonl with {"prompt","chosen","rejected"} for the bridge's
  # DPO path. Pairs naturally with the RL practice loop: the model's passing
  # attempts are `chosen`, its failing ones `rejected`.
  class PreferenceDataset
    record Triple, prompt : String, chosen : String, rejected : String
    getter triples = [] of Triple

    def add(prompt : String, chosen : String, rejected : String) : self
      raise ArgumentError.new("prompt cannot be blank") if prompt.blank?
      raise ArgumentError.new("chosen/rejected cannot be blank") if chosen.blank? || rejected.blank?
      @triples << Triple.new(prompt, chosen, rejected)
      self
    end

    def size : Int32
      @triples.size
    end

    def self.from_jsonl(path : Path | String) : PreferenceDataset
      ds = new
      File.each_line(Path[path].expand.to_s) do |line|
        next if line.blank?
        row = JSON.parse(line)
        ds.add(row["prompt"].as_s, row["chosen"].as_s, row["rejected"].as_s)
      end
      ds
    end

    def write(directory : Path | String) : Path
      raise ArgumentError.new("Cannot write an empty preference dataset") if @triples.empty?
      dir = Path[directory].expand
      FileUtils.mkdir_p(dir.to_s)
      File.open(dir.join("train.jsonl").to_s, "w") do |f|
        @triples.each { |t| f.puts({prompt: t.prompt, chosen: t.chosen, rejected: t.rejected}.to_json) }
      end
      dir
    end
  end

  # Weighted dataset for advantage-weighted / GRPO policy updates: each
  # (prompt, completion) carries a `weight` (a group-relative advantage). The
  # update reinforces positive-weight completions and suppresses negative-weight
  # ones. Written as train.jsonl with {"prompt","completion","weight"}.
  class WeightedDataset
    record Sample, prompt : String, completion : String, weight : Float64
    getter samples = [] of Sample

    def add(prompt : String, completion : String, weight : Float64) : self
      raise ArgumentError.new("prompt/completion cannot be blank") if prompt.blank? || completion.blank?
      @samples << Sample.new(prompt, completion, weight)
      self
    end

    def size : Int32
      @samples.size
    end

    def write(directory : Path | String) : Path
      raise ArgumentError.new("Cannot write an empty weighted dataset") if @samples.empty?
      dir = Path[directory].expand
      FileUtils.mkdir_p(dir.to_s)
      File.open(dir.join("train.jsonl").to_s, "w") do |f|
        @samples.each { |s| f.puts({prompt: s.prompt, completion: s.completion, weight: s.weight}.to_json) }
      end
      dir
    end
  end
end
