# Memory probe: load a model, report its base-load memory, then train a FEW
# QLoRA iters at a configurable batch size, printing every iteration so an
# external monitor can correlate progress with physical footprint.
#   ITERS=30 BATCH=1 crystal run examples/_mem_probe.cr -- mlx-community/gemma-3-12b-it-4bit
require "../src/llamero"

MODEL = ARGV[0]? || abort "usage: _mem_probe.cr -- <model>"
PAIRS = Path[__DIR__].parent.join("training_data", "fsdd_feature_story.jsonl")
SYSTEM = "You are an FSDD feature-story analyst. Output one JSON object structuring the request as a feature story."
ITERS = (ENV["ITERS"]?.try(&.to_i?) || 30)
BATCH = (ENV["BATCH"]?.try(&.to_i?) || 1)
NAME = "fsdd-fs-#{MODEL.split('/').last.gsub(/[^A-Za-z0-9_.-]/, "-")}-memprobe"

bridge = Llamero::Native::MLXBridge.try_load
abort "no bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model
mb = session.load_metrics.try(&.memory_bytes) || 0_i64
puts "LOADED load_count=#{session.load_count} base_load_mem=#{(mb / 1_073_741_824.0).round(2)}GB"

dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
  PAIRS, system_prompt: SYSTEM, format: Llamero::Native::TrainingDataset.template_for(MODEL)
)
cfg = Llamero::Native::AdapterTrainingConfig.new
cfg.iterations = ITERS
cfg.batch_size = BATCH
cfg.learning_rate = 1e-4
cfg.steps_per_report = 1
cfg.num_layers = (ENV["LAYERS"]?.try(&.to_i?) || cfg.num_layers)
cfg.rank = (ENV["RANK"]?.try(&.to_i?) || cfg.rank)
puts "training probe: batch=#{BATCH} iters=#{ITERS} num_layers=#{cfg.num_layers} rank=#{cfg.rank}"
session.train_adapter(NAME, dataset, cfg) do |p|
  puts "iter #{p.iteration}/#{p.total_iterations} loss=#{p.loss.round(3)} #{p.tokens_per_second.round(0)}tok/s"
end
puts "PROBE DONE"
runtime.close
