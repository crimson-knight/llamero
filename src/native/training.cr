require "json"
require "file_utils"
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
  # files. The default template is ChatML, which matches Qwen-family models;
  # pass a custom `format` proc for models with different special tokens.
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

    getter pairs = [] of Pair
    property system_prompt : String?

    def initialize(
      @system_prompt : String? = nil,
      @format : Proc(Pair, String?, String) = CHATML
    )
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
      format : Proc(Pair, String?, String) = CHATML
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

    def size : Int32
      @pairs.size
    end

    # Writes train.jsonl and valid.jsonl into the directory and returns it.
    #
    # The validation split is deterministic (every Nth example) so runs are
    # reproducible; with very small datasets the first example is reused for
    # validation so there is always something to score against.
    def write(directory : Path | String, valid_fraction : Float64 = 0.1) : Path
      raise ArgumentError.new("Cannot write an empty training dataset") if @pairs.empty?
      unless valid_fraction >= 0.0 && valid_fraction < 1.0
        raise ArgumentError.new("valid_fraction must be in [0, 1)")
      end

      dir = Path[directory].expand
      FileUtils.mkdir_p(dir.to_s)

      texts = @pairs.map { |pair| @format.call(pair, @system_prompt) }

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
end
