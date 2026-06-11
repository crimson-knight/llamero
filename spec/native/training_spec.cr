require "../spec_helper"
require "file_utils"

private def tmp_dir : String
  File.join(Dir.tempdir, "llamero-training-#{Random::Secure.hex(6)}")
end

private def sample_dataset : Llamero::Native::TrainingDataset
  dataset = Llamero::Native::TrainingDataset.new(system_prompt: "You are a bulldozer expert.")
  dataset.add("What are the LX-900 injector specs?", "BR-7741 injectors at 2,150 PSI.")
  dataset.add("What oil does the LX-900 use?", "15W-40 heavy duty diesel oil.")
  dataset.add("How often to grease the LX-900 tracks?", "Every 50 operating hours.")
  dataset.add("What is the LX-900 fuel tank capacity?", "420 liters.")
  dataset
end

# Simplified versions of real HF chat templates, restricted to constructs
# crinja supports (no python slicing / method calls).
private CHATML_TEMPLATE = "{% for message in messages %}<|im_start|>{{ message['role'] }}\n" \
                          "{{ message['content'] }}<|im_end|>\n{% endfor %}" \
                          "{% if add_generation_prompt %}<|im_start|>assistant\n{% endif %}"

private GEMMA_TEMPLATE = "{{ bos_token }}{% for message in messages %}" \
                         "{% if message['role'] == 'assistant' %}{% set role = 'model' %}" \
                         "{% else %}{% set role = message['role'] %}{% endif %}" \
                         "<start_of_turn>{{ role }}\n{{ message['content'] }}<end_of_turn>\n{% endfor %}"

private def model_dir_with_tokenizer_config(dir : String, config) : Path
  FileUtils.mkdir_p(dir)
  File.write(File.join(dir, "tokenizer_config.json"), config.to_json)
  Path[dir]
end

describe Llamero::Native::TrainingDataset do
  it "renders pairs through the ChatML template into train/valid JSONL" do
    dir = tmp_dir
    begin
      data_dir = sample_dataset.write(dir, valid_fraction: 0.25)

      train_lines = File.read_lines(data_dir.join("train.jsonl").to_s)
      valid_lines = File.read_lines(data_dir.join("valid.jsonl").to_s)

      train_lines.size.should eq(3)
      valid_lines.size.should eq(1)

      first = JSON.parse(train_lines.first)["text"].as_s
      first.should contain("<|im_start|>system\nYou are a bulldozer expert.<|im_end|>")
      first.should contain("<|im_start|>user\nWhat are the LX-900 injector specs?<|im_end|>")
      first.should contain("<|im_start|>assistant\nBR-7741 injectors at 2,150 PSI.<|im_end|>")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "never produces an empty validation split" do
    dir = tmp_dir
    begin
      dataset = Llamero::Native::TrainingDataset.new
      dataset.add("only prompt", "only completion")
      data_dir = dataset.write(dir)

      File.read_lines(data_dir.join("train.jsonl").to_s).size.should eq(1)
      File.read_lines(data_dir.join("valid.jsonl").to_s).size.should eq(1)
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "rejects empty datasets and blank pairs" do
    expect_raises(ArgumentError, /empty/) do
      Llamero::Native::TrainingDataset.new.write(tmp_dir)
    end
    expect_raises(ArgumentError, /blank/) do
      Llamero::Native::TrainingDataset.new.add("", "completion")
    end
  end

  it "loads raw prompt/completion pairs from a JSONL file" do
    dir = tmp_dir
    begin
      FileUtils.mkdir_p(dir)
      pairs_path = File.join(dir, "pairs.jsonl")
      File.write(pairs_path, <<-JSONL)
        {"prompt": "What is X?", "completion": "X is a thing."}

        {"prompt": "What is Y?", "completion": "Y is another thing."}
        JSONL

      dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
        pairs_path, system_prompt: "You are terse."
      )
      dataset.size.should eq(2)
      dataset.pairs.first.prompt.should eq("What is X?")
      dataset.system_prompt.should eq("You are terse.")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "rejects missing or malformed pairs files" do
    expect_raises(ArgumentError, /not found/) do
      Llamero::Native::TrainingDataset.from_pairs_jsonl("/nonexistent/pairs.jsonl")
    end

    dir = tmp_dir
    begin
      FileUtils.mkdir_p(dir)
      bad_path = File.join(dir, "bad.jsonl")
      File.write(bad_path, %({"prompt": "no completion field"}\n))
      expect_raises(ArgumentError, /completion/) do
        Llamero::Native::TrainingDataset.from_pairs_jsonl(bad_path)
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "renders the Gemma template with the system prompt folded into the user turn" do
    pair = Llamero::Native::TrainingDataset::Pair.new("What is X?", "X is a thing.")
    text = Llamero::Native::TrainingDataset::GEMMA.call(pair, "You are terse.")
    text.should eq(
      "<start_of_turn>user\nYou are terse.\n\nWhat is X?<end_of_turn>\n" \
      "<start_of_turn>model\nX is a thing.<end_of_turn>"
    )
  end

  it "selects the chat template matching a model id" do
    Llamero::Native::TrainingDataset.template_for("mlx-community/gemma-4-e2b-it-4bit")
      .should eq(Llamero::Native::TrainingDataset::GEMMA)
    Llamero::Native::TrainingDataset.template_for("mlx-community/Qwen3-0.6B-4bit")
      .should eq(Llamero::Native::TrainingDataset::CHATML)
  end

  it "tracks whether the format was chosen explicitly" do
    Llamero::Native::TrainingDataset.new.format_explicit?.should be_false
    Llamero::Native::TrainingDataset.new.template_source.should eq("default")

    explicit = Llamero::Native::TrainingDataset.new(format: Llamero::Native::TrainingDataset::GEMMA)
    explicit.format_explicit?.should be_true
    explicit.template_source.should eq("explicit")
  end

  it "loads the shipped llamero API golden dataset" do
    dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
      Path[__DIR__].parent.parent.join("training_data", "llamero_api_qa.jsonl")
    )
    dataset.size.should be >= 40
    dataset.pairs.any? { |pair| pair.completion.includes?("load_model") }.should be_true
  end
end

describe "Llamero::Native::TrainingDataset.template_from" do
  pair = Llamero::Native::TrainingDataset::Pair.new("What is X?", "X is a thing.")

  it "renders through a ChatML-style chat_template from tokenizer_config.json" do
    dir = tmp_dir
    begin
      model_dir = model_dir_with_tokenizer_config(dir, {"chat_template" => CHATML_TEMPLATE})

      format = Llamero::Native::TrainingDataset.template_from(model_dir).not_nil!
      format.call(pair, "You are terse.").should eq(
        "<|im_start|>system\nYou are terse.<|im_end|>\n" \
        "<|im_start|>user\nWhat is X?<|im_end|>\n" \
        "<|im_start|>assistant\nX is a thing.<|im_end|>\n"
      )
      format.call(pair, nil).should eq(
        "<|im_start|>user\nWhat is X?<|im_end|>\n" \
        "<|im_start|>assistant\nX is a thing.<|im_end|>\n"
      )
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "renders a Gemma-style template with bos_token read from an AddedToken object" do
    dir = tmp_dir
    begin
      model_dir = model_dir_with_tokenizer_config(dir, {
        "chat_template" => GEMMA_TEMPLATE,
        "bos_token"     => {"content" => "<bos>", "lstrip" => false},
        "eos_token"     => "<eos>",
      })

      format = Llamero::Native::TrainingDataset.template_from(model_dir).not_nil!
      format.call(pair, nil).should eq(
        "<bos><start_of_turn>user\nWhat is X?<end_of_turn>\n" \
        "<start_of_turn>model\nX is a thing.<end_of_turn>\n"
      )
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "picks the default entry when chat_template is a list of named templates" do
    dir = tmp_dir
    begin
      model_dir = model_dir_with_tokenizer_config(dir, {
        "chat_template" => [
          {"name" => "tool_use", "template" => "{{ unsupported_function() }}"},
          {"name" => "default", "template" => CHATML_TEMPLATE},
        ],
      })

      format = Llamero::Native::TrainingDataset.template_from(model_dir).not_nil!
      format.call(pair, nil).should contain("<|im_start|>user\nWhat is X?<|im_end|>")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "tolerates tokenizer_config values JSON.parse rejects (Gemma's > Int64 model_max_length)" do
    dir = tmp_dir
    begin
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "tokenizer_config.json"), String.build do |json|
        json << %({"model_max_length": 1000000000000000019884624838656, )
        json << %("bos_token": "<bos>", "chat_template": ) << GEMMA_TEMPLATE.to_json << "}"
      end)

      format = Llamero::Native::TrainingDataset.template_from(dir).not_nil!
      format.call(pair, nil).should start_with("<bos><start_of_turn>user\n")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "falls back to a standalone chat_template.jinja file" do
    dir = tmp_dir
    begin
      model_dir = model_dir_with_tokenizer_config(dir, {"model_max_length" => 4096})
      File.write(model_dir.join("chat_template.jinja").to_s, CHATML_TEMPLATE)

      format = Llamero::Native::TrainingDataset.template_from(model_dir).not_nil!
      format.call(pair, nil).should contain("<|im_start|>assistant\nX is a thing.<|im_end|>")
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "returns nil for templates with constructs crinja cannot handle" do
    dir = tmp_dir
    begin
      # Python slice syntax - used by real Gemma/Llama HF templates.
      model_dir = model_dir_with_tokenizer_config(dir, {
        "chat_template" => "{% for message in messages[1:] %}{{ message['content'] }}{% endfor %}",
      })
      Llamero::Native::TrainingDataset.template_from(model_dir).should be_nil

      # Python method calls fail at render time rather than parse time.
      model_dir = model_dir_with_tokenizer_config(dir, {
        "chat_template" => "{{ messages[0]['content'].strip() }}",
      })
      Llamero::Native::TrainingDataset.template_from(model_dir).should be_nil

      # raise_exception is wired up, so templates that reject our message
      # shape are detected by the probe render and fall back cleanly.
      model_dir = model_dir_with_tokenizer_config(dir, {
        "chat_template" => "{{ raise_exception('unsupported message shape') }}",
      })
      Llamero::Native::TrainingDataset.template_from(model_dir).should be_nil
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "returns nil when the model directory has no chat template" do
    dir = tmp_dir
    begin
      FileUtils.mkdir_p(dir)
      Llamero::Native::TrainingDataset.template_from(dir).should be_nil

      model_dir_with_tokenizer_config(dir, {"model_max_length" => 4096})
      Llamero::Native::TrainingDataset.template_from(dir).should be_nil
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "returns nil for a missing directory" do
    Llamero::Native::TrainingDataset.template_from("/nonexistent/model/dir").should be_nil
  end
end

describe Llamero::Native::AdapterTrainingConfig do
  it "validates hyperparameters" do
    config = Llamero::Native::AdapterTrainingConfig.new
    config.validate!

    config.rank = 0
    expect_raises(ArgumentError, /rank/) { config.validate! }

    config = Llamero::Native::AdapterTrainingConfig.new
    config.learning_rate = 0.0
    expect_raises(ArgumentError, /learning_rate/) { config.validate! }
  end
end

describe "Llamero::Native::ModelSession#train_adapter" do
  it "trains, registers, and can activate the resulting adapter without reloading" do
    dir = tmp_dir
    begin
      bridge = Llamero::Native::MockBridge.new
      runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: bridge)
      session = runtime.start_session
      session.load_model

      losses = [] of Float64
      descriptor = session.train_adapter("lx900", sample_dataset, output_dir: dir) do |progress|
        losses << progress.loss
      end

      # Deterministic mock loss curve decreases.
      losses.size.should be > 1
      losses.first.should be > losses.last

      descriptor.name.should eq("lx900")
      descriptor.path.should eq(Path[dir].expand.to_s)
      File.exists?(Path[dir].join("adapters.safetensors")).should be_true
      File.exists?(Path[dir].join("adapter_config.json")).should be_true
      runtime.adapters.registered?("lx900").should be_true

      summary = session.last_training.not_nil!
      summary.final_loss.should be > 0
      summary.final_validation_loss.not_nil!.should be > summary.final_loss
      summary.iterations.should eq(200)

      # The dataset was written alongside the adapter artifact.
      File.exists?(Path[dir].join("dataset", "train.jsonl")).should be_true

      # Round-trip: activate the trained adapter on the resident model.
      session.activate_adapters(
        Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("lx900")])
      )
      session.active_adapter_stack.slots.map(&.name).should eq(["lx900"])
      session.load_count.should eq(1)
      session.base_model_reloaded?.should be_false
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "auto-renders default-format datasets through the model's own chat template" do
    dir = tmp_dir
    model_dir = tmp_dir
    begin
      model_dir_with_tokenizer_config(model_dir, {
        "chat_template" => GEMMA_TEMPLATE,
        "bos_token"     => "<bos>",
      })

      runtime = Llamero::Native::MLXRuntime.new(
        model_id: "test-model", model_path: model_dir, bridge: Llamero::Native::MockBridge.new
      )
      session = runtime.start_session
      session.load_model

      dataset = sample_dataset
      session.train_adapter("own-template", dataset, output_dir: dir)

      dataset.template_source.should eq("model-chat-template")
      first = JSON.parse(File.read_lines(Path[dir].join("dataset", "train.jsonl").to_s).first)["text"].as_s
      first.should start_with("<bos><start_of_turn>system\nYou are a bulldozer expert.<end_of_turn>\n")
      first.should contain("<start_of_turn>model\nBR-7741 injectors at 2,150 PSI.<end_of_turn>")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(model_dir)
    end
  end

  it "falls back to the built-in family template when the model ships no usable template" do
    dir = tmp_dir
    model_dir = tmp_dir
    begin
      # Real Gemma templates use python slicing, which crinja cannot parse.
      model_dir_with_tokenizer_config(model_dir, {
        "chat_template" => "{% for m in messages[1:] %}{{ m['content'] }}{% endfor %}",
      })

      runtime = Llamero::Native::MLXRuntime.new(
        model_id: "mlx-community/gemma-3-1b-it-4bit", model_path: model_dir, bridge: Llamero::Native::MockBridge.new
      )
      session = runtime.start_session
      session.load_model

      dataset = sample_dataset
      session.train_adapter("fallback-template", dataset, output_dir: dir)

      dataset.template_source.should eq("built-in")
      first = JSON.parse(File.read_lines(Path[dir].join("dataset", "train.jsonl").to_s).first)["text"].as_s
      first.should start_with("<start_of_turn>user\nYou are a bulldozer expert.")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(model_dir)
    end
  end

  it "never overrides an explicitly chosen format" do
    dir = tmp_dir
    model_dir = tmp_dir
    begin
      model_dir_with_tokenizer_config(model_dir, {"chat_template" => GEMMA_TEMPLATE})

      runtime = Llamero::Native::MLXRuntime.new(
        model_id: "test-model", model_path: model_dir, bridge: Llamero::Native::MockBridge.new
      )
      session = runtime.start_session
      session.load_model

      dataset = Llamero::Native::TrainingDataset.new(format: Llamero::Native::TrainingDataset::CHATML)
      dataset.add("What is X?", "X is a thing.")
      session.train_adapter("explicit-format", dataset, output_dir: dir)

      dataset.template_source.should eq("explicit")
      first = JSON.parse(File.read_lines(Path[dir].join("dataset", "train.jsonl").to_s).first)["text"].as_s
      first.should start_with("<|im_start|>user\n")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(model_dir)
    end
  end

  it "accepts a pre-existing dataset directory" do
    dir = tmp_dir
    data_dir = tmp_dir
    begin
      sample_dataset.write(data_dir)
      bridge = Llamero::Native::MockBridge.new
      runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: bridge)
      session = runtime.start_session
      session.load_model

      descriptor = session.train_adapter("from-dir", data_dir, output_dir: dir)
      descriptor.name.should eq("from-dir")
    ensure
      FileUtils.rm_rf(dir)
      FileUtils.rm_rf(data_dir)
    end
  end

  it "rejects dataset directories without training files" do
    dir = tmp_dir
    begin
      FileUtils.mkdir_p(dir)
      runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: Llamero::Native::MockBridge.new)
      session = runtime.start_session
      session.load_model

      expect_raises(ArgumentError, /train.jsonl/) do
        session.train_adapter("nope", dir)
      end
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "requires a loaded model" do
    session = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: Llamero::Native::MockBridge.new).start_session

    expect_raises(Llamero::Native::SessionStateError, /not loaded/) do
      session.train_adapter("early", sample_dataset)
    end
  end

  it "surfaces training failures as AdapterTrainingError with the model still resident" do
    dir = tmp_dir
    begin
      bridge = Llamero::Native::MockBridge.new
      runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: bridge)
      session = runtime.start_session
      session.load_model

      bridge.fail_next_training = true
      error = expect_raises(Llamero::Native::AdapterTrainingError) do
        session.train_adapter("boom", sample_dataset, output_dir: dir)
      end

      error.base_model_loaded.should be_true
      session.loaded?.should be_true
      runtime.adapters.registered?("boom").should be_false

      # Session keeps generating after the failure.
      session.chat([Llamero::Message.user("still alive?")]).content.should contain("mock response")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end
