# Measures the SFT loss of the Grant training rows on the resident model at
# each step of the path from a trained adapter to inference, so a train/serve
# gap can be localized to one stage:
#
#   base -> stage-0 fused (the base stage-1 trained on) -> stage-1 live (the
#   training state) -> stage-1 fused (the public inference path)
#
# plus stage-1 applied alone to the unmodified base, live and fused.
#
#   crystal-alpha run scripts/measure_amber_grant_train_serve_loss.cr -- \
#     FILTER_PATH PROBE_DIR ARTIFACT.jsonl [full-sequence|completion-only]
require "../src/llamero"
require "json"
require "file_utils"

class AmberTrainServeLossRecord
  include JSON::Serializable

  getter filter_id : String
  getter configuration : String
  getter description : String
  getter? completion_only_loss : Bool
  getter rows : Int32
  getter loss : Float64
  getter list_of_first_five_row_losses : Array(Float64)
  getter list_of_row_losses : Array(Float64)
  getter list_of_adapter_key_remaps : Array(String)

  def initialize(
    @filter_id : String,
    @configuration : String,
    @description : String,
    @completion_only_loss : Bool,
    @rows : Int32,
    @loss : Float64,
    @list_of_row_losses : Array(Float64),
    @list_of_adapter_key_remaps : Array(String),
  )
    @list_of_first_five_row_losses = @list_of_row_losses.first(5)
  end
end

PINNED_MODEL = "mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2"
MODEL_PATH   = Path.home.join(".llamero", "models", "mlx-community--gemma-3-4b-it-4bit")

filter_path = ARGV[0]? || abort "usage: FILTER_PATH PROBE_DIR ARTIFACT.jsonl [full-sequence|completion-only]"
probe_dir = Path[ARGV[1]? || abort "missing PROBE_DIR"].expand
artifact_path = Path[ARGV[2]? || abort "missing ARTIFACT.jsonl"].expand
loss_mode = ARGV[3]? || "completion-only"
unless ["full-sequence", "completion-only"].includes?(loss_mode)
  abort "loss mode must be full-sequence or completion-only; got #{loss_mode}"
end
completion_only_loss = loss_mode == "completion-only"
abort "refusing to overwrite #{artifact_path}" if File.exists?(artifact_path)
abort "probe rows missing: #{probe_dir}/train.jsonl" unless File.exists?(probe_dir.join("train.jsonl"))

filter = Llamero::Native::TrainingFilter.load(filter_path)
list_of_expected_base_models = [PINNED_MODEL, PINNED_MODEL.sub(/@[^@]+$/, "")]
abort "filter base mismatch: #{filter.manifest.base_model}" unless list_of_expected_base_models.includes?(filter.manifest.base_model)
list_of_stage_dirs = filter.stage_dirs
abort "#{filter.id} must be a chain with at least two stages" unless list_of_stage_dirs.size >= 2

bridge = Llamero::Native::MLXBridge.try_load
abort "no MLX bridge; refusing to measure mock output" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: PINNED_MODEL, model_path: MODEL_PATH.to_s, bridge: bridge)
list_of_stage_names = list_of_stage_dirs.map_with_index do |dir, index|
  stage_name = "#{filter.name}-measure-stage-#{index}"
  runtime.adapters.register(stage_name, dir)
  stage_name
end
final_stage_name = list_of_stage_names.last
list_of_prior_stage_names = list_of_stage_names[0...-1]
session = runtime.start_session

FileUtils.mkdir_p(artifact_path.parent.to_s)
artifact = File.open(artifact_path.to_s, "w")

measure = ->(configuration : String, description : String) do
  evaluation = session.evaluate_loss(configuration, probe_dir, completion_only_loss)
  record = AmberTrainServeLossRecord.new(
    filter_id: filter.id,
    configuration: configuration,
    description: description,
    completion_only_loss: completion_only_loss,
    rows: evaluation.rows,
    loss: evaluation.loss,
    list_of_row_losses: evaluation.row_losses,
    list_of_adapter_key_remaps: session.last_adapter_key_remaps,
  )
  artifact.puts(record.to_json)
  artifact.flush
  puts "#{configuration}: loss=#{evaluation.loss.round(4)} rows=#{evaluation.rows} first5=#{record.list_of_first_five_row_losses.map(&.round(3))}"
end

fuse_prior_stages = -> do
  session.load_model
  list_of_prior_stage_names.each do |stage_name|
    session.activate_adapters(
      Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new(stage_name)]),
      fuse: true, cumulative: true)
  end
end
final_stage = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new(final_stage_name)])

session.load_model
measure.call("base", "pinned base, no adapter")

fuse_prior_stages.call
measure.call("prior-stages-fused", "stages before the final one cumulatively fused: the base the final stage trained on")

session.activate_adapters(final_stage)
measure.call("final-stage-live", "prior stages fused, final stage as live LoRA layers: the training-time state")

fuse_prior_stages.call
session.activate_adapters(final_stage, fuse: true, cumulative: true)
measure.call("final-stage-fused", "every stage cumulatively fused and re-quantized: the public activate_filter path")

session.load_model
session.activate_filter(filter, fuse: true)
measure.call("activate-filter", "session.activate_filter(filter, fuse: true), exactly as scripts/eval_amber_grant_filter.cr")

session.load_model
session.activate_adapters(final_stage)
measure.call("final-stage-only-live", "final stage alone on the unmodified base, live LoRA layers")

session.load_model
session.activate_adapters(final_stage, fuse: true, cumulative: true)
measure.call("final-stage-only-fused", "final stage alone on the unmodified base, fused and re-quantized")

artifact.close
runtime.close
puts "artifact: #{artifact_path}"
