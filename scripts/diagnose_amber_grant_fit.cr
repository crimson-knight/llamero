require "../src/llamero"
require "json"
require "file_utils"

class AmberGrantFitTrainingPair
  include JSON::Serializable

  property prompt : String = ""
  property completion : String = ""
end

class AmberGrantFitModelFile
  include JSON::Serializable

  property name : String = ""
  property lfs_sha256 : String = ""
end

class AmberGrantFitModelPin
  include JSON::Serializable

  property model_id : String = ""
  property pinned_model_id : String = ""
  property local_cache_relative_dir : String = ""
  property files : Array(AmberGrantFitModelFile) = [] of AmberGrantFitModelFile
end

class AmberGrantFitLossRecord
  include JSON::Serializable

  property kind : String = "train_loss"
  property iteration : Int32 = 0
  property loss : Float64 = 0.0

  def initialize(@iteration : Int32, @loss : Float64)
  end
end

class AmberGrantFitSummaryRecord
  include JSON::Serializable

  property kind : String = "summary"
  property model_id : String = ""
  property model_weights_sha256 : String = ""
  property source_filter_id : String = ""
  property source_filter_weights_checksum : String = ""
  property training_rows : Int32 = 0
  property grant_probe_rows : Int32 = 0
  property template_source : String = ""
  property completion_only_loss : Bool = false
  property iterations : Int32 = 0
  property rank : Int32 = 0
  property num_layers : Int32 = 0
  property learning_rate : Float64 = 0.0
  property batch_size : Int32 = 0
  property steps_per_report : Int32 = 0
  property initial_train_loss : Float64? = nil
  property final_train_loss : Float64 = 0.0
  property final_validation_loss : Float64?
  property grant_loss_before : Float64?
  property grant_loss_after : Float64?
  property total_time_ms : Float64 = 0.0
  property adapter_output_path : String = ""

  def initialize
  end
end

class AmberGrantFitTokenPreviewRecord
  include JSON::Serializable

  property kind : String = "training_tokenization_preview"
  property preview_id : String = ""
  property template_source : String = "built-in"
  property system_prompt : String = ""
  property rendered_text : String = ""
  property token_count : Int32 = 0
  property token_ids : Array(Int32) = [] of Int32
  property decoded_text : String = ""

  def initialize
  end
end

ROOT               = Path[__DIR__].parent
PIN_PATH           = ROOT.join("training_data", "amber", "gemma3_4b_model_pin.json")
CORPUS_PATH        = ROOT.join("training_data", "amber", "amber_v2_sft.jsonl")
GRANT_PAIRS_PATH   = ROOT.join("training_data", "amber", "grant_tenancy_rawsql_pairs.jsonl")
SOURCE_FILTER_PATH = Path.home.join(".llamero", "filters", "amber-v2-0.2.0.filter")
MODEL_PATH         = Path.home.join(".llamero", "models", "mlx-community--gemma-3-4b-it-4bit")
WORK_PATH          = ROOT.join(".crystal-cache", "round3b-fit100")
ADAPTER_PATH       = WORK_PATH.join("adapter")
PROBE_PATH         = WORK_PATH.join("grant-loss-probe")
LOSS_PATH          = ROOT.join("training_data", "amber", "eval_results", "round3b-fit100-loss.jsonl")
TOKEN_PREVIEW_PATH = ROOT.join("training_data", "amber", "eval_results", "round3b-fit100-token-preview.jsonl")
REPORT_PATH        = ROOT.join("training_data", "amber", "eval_results", "round3b-fit100-diagnostic.md")

SYSTEM_PROMPT          = "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."
EXPECTED_TRAINING_ROWS =  296
EXPECTED_GRANT_ROWS    =   84
ITERATIONS             =  100
RANK                   =    8
NUM_LAYERS             =   16
LEARNING_RATE          = 1e-4
BATCH_SIZE             =    1
STEPS_PER_REPORT       =    1

[
  LOSS_PATH,
  TOKEN_PREVIEW_PATH,
  REPORT_PATH,
].each do |path|
  abort "refusing to overwrite fit diagnostic output: #{path}" if File.exists?(path)
end
abort "refusing to overwrite diagnostic work directory: #{WORK_PATH}" if Dir.exists?(WORK_PATH)
abort "pinned model directory is missing: #{MODEL_PATH}" unless Dir.exists?(MODEL_PATH)
abort "SFT corpus is missing: #{CORPUS_PATH}" unless File.exists?(CORPUS_PATH)
abort "Grant training pairs are missing: #{GRANT_PAIRS_PATH}" unless File.exists?(GRANT_PAIRS_PATH)

pin = AmberGrantFitModelPin.from_json(File.read(PIN_PATH.to_s))
model_weights = pin.files.find { |file| file.name == "model.safetensors" } ||
                abort("pinned model weights SHA256 is missing")
source_filter = Llamero::Native::TrainingFilter.load(SOURCE_FILTER_PATH)
abort "fit diagnostic requires source filter 0.2.0" unless source_filter.manifest.version == "0.2.0"
abort "source filter and model pin differ" unless source_filter.manifest.base_model == pin.pinned_model_id
abort "expected the pinned dense Gemma 3 model" unless pin.pinned_model_id.includes?("gemma-3-4b-it-4bit")

training_dataset = Llamero::Native::TrainingDataset.from_corpus_jsonl(
  CORPUS_PATH,
  only: :pair,
  system_prompt: SYSTEM_PROMPT
)
abort "expected #{EXPECTED_TRAINING_ROWS} SFT rows, found #{training_dataset.pairs.size}" unless training_dataset.pairs.size == EXPECTED_TRAINING_ROWS

template = Llamero::Native::TrainingDataset.template_for(pin.model_id)
rendered_first_row = template.call(training_dataset.pairs.first, SYSTEM_PROMPT)

grant_dataset = Llamero::Native::TrainingDataset.new(system_prompt: SYSTEM_PROMPT)
grant_dataset.use_template(template, "built-in")
File.each_line(GRANT_PAIRS_PATH.to_s) do |line|
  next if line.blank?
  pair = AmberGrantFitTrainingPair.from_json(line)
  grant_dataset.add(pair.prompt, pair.completion)
end
abort "expected #{EXPECTED_GRANT_ROWS} Grant loss-probe rows, found #{grant_dataset.pairs.size}" unless grant_dataset.pairs.size == EXPECTED_GRANT_ROWS

bridge = Llamero::Native::MLXBridge.try_load
abort "no real MLX bridge; refusing a mock fit diagnostic" unless bridge
runtime = Llamero::Native::MLXRuntime.new(
  model_id: pin.pinned_model_id,
  model_path: MODEL_PATH.to_s,
  bridge: bridge
)
session = runtime.start_session
session.load_model

preview = session.preview_training_tokens("amber-v2-first-sft-row", rendered_first_row)
abort "Swift tokenizer changed the rendered SFT row" unless preview.rendered_text == rendered_first_row
abort "Swift tokenizer returned inconsistent token count" unless preview.token_count == preview.token_ids.size

preview_record = AmberGrantFitTokenPreviewRecord.new
preview_record.preview_id = preview.preview_id
preview_record.template_source = "built-in"
preview_record.system_prompt = SYSTEM_PROMPT
preview_record.rendered_text = preview.rendered_text
preview_record.token_count = preview.token_count
preview_record.token_ids = preview.token_ids
preview_record.decoded_text = preview.decoded_text
File.write(TOKEN_PREVIEW_PATH.to_s, preview_record.to_json + "\n")

puts "training rows=#{training_dataset.pairs.size} template=built-in-GEMMA3"
puts "Grant loss probe rows=#{grant_dataset.pairs.size} template=built-in-GEMMA3"
puts "token preview count=#{preview.token_count} id=#{preview.preview_id}"
puts "rendered training row:"
puts preview.rendered_text
puts "token IDs:"
puts preview.token_ids
puts "decoded training row:"
puts preview.decoded_text
STDOUT.flush

FileUtils.mkdir_p(WORK_PATH.to_s)
probe_directory = grant_dataset.write(PROBE_PATH, valid_fraction: 0.0)
config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = ITERATIONS
config.rank = RANK
config.scale = source_filter.manifest.lora.scale
config.num_layers = NUM_LAYERS
config.batch_size = BATCH_SIZE
config.learning_rate = LEARNING_RATE
config.steps_per_report = STEPS_PER_REPORT
config.loss_probe_data_path = probe_directory.to_s
config.completion_only_loss = false

progress_rows = [] of AmberGrantFitLossRecord
training_summary_event : Llamero::Native::TrainingCompletedEvent? = nil
File.open(LOSS_PATH.to_s, "w") do |loss_file|
  session.train_adapter(
    "amber-grant-fit100",
    training_dataset,
    config,
    output_dir: ADAPTER_PATH
  ) do |progress|
    record = AmberGrantFitLossRecord.new(progress.iteration, progress.loss)
    progress_rows << record
    loss_file.puts(record.to_json)
    loss_file.flush
    puts "fit100 iteration=#{progress.iteration} loss=#{progress.loss}"
    STDOUT.flush
  end

  training_summary = session.last_training || abort("training finished without a summary")
  training_summary_event = training_summary
  summary_record = AmberGrantFitSummaryRecord.new
  summary_record.model_id = pin.pinned_model_id
  summary_record.model_weights_sha256 = model_weights.lfs_sha256
  summary_record.source_filter_id = source_filter.id
  summary_record.source_filter_weights_checksum = source_filter.manifest.weights_checksum
  summary_record.training_rows = training_dataset.pairs.size
  summary_record.grant_probe_rows = training_summary.grant_probe_rows || 0
  summary_record.template_source = training_dataset.template_source
  summary_record.completion_only_loss = training_summary.completion_only_loss
  summary_record.iterations = training_summary.iterations
  summary_record.rank = RANK
  summary_record.num_layers = NUM_LAYERS
  summary_record.learning_rate = LEARNING_RATE
  summary_record.batch_size = BATCH_SIZE
  summary_record.steps_per_report = STEPS_PER_REPORT
  summary_record.initial_train_loss = progress_rows.first?.try(&.loss)
  summary_record.final_train_loss = training_summary.final_loss
  summary_record.final_validation_loss = training_summary.final_validation_loss
  summary_record.grant_loss_before = training_summary.grant_loss_before
  summary_record.grant_loss_after = training_summary.grant_loss_after
  summary_record.total_time_ms = training_summary.total_time_ms
  summary_record.adapter_output_path = training_summary.adapter_path
  loss_file.puts(summary_record.to_json)
  loss_file.flush
end

runtime.close
training_summary = training_summary_event || abort("training summary was not recorded")

losses = progress_rows.map(&.loss)
markdown = String.build do |report|
  report << "# Round 3b 100-step Grant fit diagnostic\n\n"
  report << "- Model: `#{pin.pinned_model_id}`; weights SHA256 `#{model_weights.lfs_sha256}`.\n"
  report << "- Source filter: `#{source_filter.id}` (`#{source_filter.manifest.weights_checksum}`).\n"
  report << "- Run: SFT-only from pinned base, #{training_summary.iterations} iterations, rank #{RANK}, #{NUM_LAYERS} layers, learning rate #{LEARNING_RATE}, batch size #{BATCH_SIZE}, steps per report #{STEPS_PER_REPORT}.\n"
  report << "- Rows: #{training_summary.grant_probe_rows || 0} Grant loss-probe rows; #{training_dataset.pairs.size} Amber SFT rows.\n"
  report << "- Template: `#{training_dataset.template_source}`; `template_from` availability `#{Llamero::Native::TrainingDataset.template_from(MODEL_PATH.to_s).nil? ? "nil" : "resolved"}`.\n"
  report << "- Completion-only loss (prompt masking): `#{training_summary.completion_only_loss}`.\n"
  report << "- Train loss: #{progress_rows.size} per-step reports; first #{losses.first? || 0.0}, final #{training_summary.final_loss}, minimum #{losses.min? || 0.0}, maximum #{losses.max? || 0.0}.\n"
  report << "- Grant loss: #{training_summary.grant_loss_before || 0.0} before -> #{training_summary.grant_loss_after || 0.0} after.\n"
  report << "- Validation loss at end: #{training_summary.final_validation_loss || 0.0}. Elapsed: #{training_summary.total_time_ms.round(0)} ms.\n"
  report << "- Token preview: [`round3b-fit100-token-preview.jsonl`](round3b-fit100-token-preview.jsonl); it uses the same `SpecialTokenAwareTrainingTokenizer` as SFT and stores the rendered row, token IDs, and decoded text.\n"
  report << "- Upstream warning source: pinned `mlx-swift-lm` `Libraries/MLXLLM/LoraTrain.swift:50-66`. `LoRABatchIterator` warns when the current batch's longest row exceeds 2048, pads to the observed maximum, and shifts inputs/targets across the full sequence; it does not truncate. The prior full-corpus audit found 1/296 SFT rows over 2048, maximum 2148; 100 tokens would be lost only under hypothetical right truncation, while actual truncation was 0 rows.\n\n"
  report << "## Per-iteration loss\n\n"
  report << "| Iteration | Loss |\n| ---: | ---: |\n"
  progress_rows.each do |row|
    report << "| #{row.iteration} | #{row.loss.round(8)} |\n"
  end
  report << "\nRaw per-iteration reports and final summary: `round3b-fit100-loss.jsonl`.\n"
end
File.write(REPORT_PATH.to_s, markdown)

puts "fit100 reports=#{progress_rows.size}/#{ITERATIONS}"
puts "Grant loss=#{training_summary.grant_loss_before} -> #{training_summary.grant_loss_after}"
puts "completion_only_loss=#{training_summary.completion_only_loss}; template=#{training_dataset.template_source}"
puts "artifact=#{LOSS_PATH}"
puts "report=#{REPORT_PATH}"
