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

  it "loads the shipped llamero API golden dataset" do
    dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
      Path[__DIR__].parent.parent.join("training_data", "llamero_api_qa.jsonl")
    )
    dataset.size.should be >= 40
    dataset.pairs.any? { |pair| pair.completion.includes?("load_model") }.should be_true
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
