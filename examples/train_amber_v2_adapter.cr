# Train a versioned Amber V2 filter from the grounded SFT corpus. Held-out
# scoring is handled by scripts/eval_amber_grant_filter.cr so the same questions
# and compile/symbol gates run before and after training.
#
#   crystal-alpha run examples/train_amber_v2_adapter.cr -- [MODEL] [UNSUP_ITERS]
#     [SFT_ITERS] [FILTER_VERSION] [FILTER_PATH] [MODEL_PATH]
require "../src/llamero"
require "json"
require "file_utils"

class AmberV2TrainingRow
  include JSON::Serializable

  property kind : String = ""
  property completion : String = ""
end

PINNED_MODEL   = "mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2"
MODEL          = ARGV[0]? || PINNED_MODEL
UNSUP_ITER     = (ARGV[1]? || "200").to_i
SFT_ITER       = (ARGV[2]? || "400").to_i
FILTER_VERSION = ARGV[3]? || "0.2.0"
FILTER_PATH    = Path[ARGV[4]? || Path.home.join(".llamero", "filters", "amber-v2-#{FILTER_VERSION}.filter").to_s].expand
MODEL_PATH     = Path[ARGV[5]? || Path.home.join(".llamero", "models", "mlx-community--gemma-3-4b-it-4bit").to_s].expand
CORPUS         = Path[__DIR__].parent.join("training_data", "amber", "amber_v2_sft.jsonl")
SYSTEM         = "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."

abort "refusing to overwrite an existing filter: #{FILTER_PATH}" if File.exists?(FILTER_PATH)
abort "verified model directory is missing: #{MODEL_PATH}" unless Dir.exists?(MODEL_PATH)

bridge = Llamero::Native::MLXBridge.try_load
abort "no MLX bridge — build native/llamero-mlx (./build.sh) first" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, model_path: MODEL_PATH.to_s, bridge: bridge)
session = runtime.start_session
session.load_model

# Build datasets: unsupervised on the completions (absorb v2 syntax/vocab), then
# SFT on the instruction->code pairs (idiomatic usage + format).
abort "corpus missing: #{CORPUS}" unless File.exists?(CORPUS)
completions = [] of String
pairs_count = 0
File.each_line(CORPUS.to_s) do |line|
  next if line.blank?
  row = AmberV2TrainingRow.from_json(line)
  if row.kind == "pair" && !row.completion.empty?
    completions << row.completion
    pairs_count += 1
  end
end
puts "\ncorpus: #{pairs_count} grounded Amber v2 pairs from #{CORPUS}"

text_ds = Llamero::Native::TrainingDataset.from_text(completions)
sft_ds = Llamero::Native::TrainingDataset.from_corpus_jsonl(CORPUS, only: :pair, system_prompt: SYSTEM)

def cfg(iters)
  c = Llamero::Native::AdapterTrainingConfig.new
  c.iterations = iters
  c.rank = 8
  c.scale = 1.0
  c.num_layers = 16
  c.batch_size = 1
  c.learning_rate = 1e-4
  c.steps_per_report = 50
  c
end

pipeline = Llamero::Native::StagedPipeline.new(session, "amber-v2-#{FILTER_VERSION}")
pipeline.unsupervised("syntax", text_ds, cfg(UNSUP_ITER))
pipeline.supervised("usage", sft_ds, cfg(SFT_ITER))
puts "\n=== training (unsupervised #{UNSUP_ITER} -> SFT #{SFT_ITER}, fuse-forward) ==="
results = pipeline.run { |i, name| puts "  stage #{i}: #{name} (#{Time.local})" }

# Ship the composed adapter as a distributable chain filter.
FileUtils.mkdir_p(FILTER_PATH.parent.to_s)
filter = Llamero::Native::TrainingFilter.pack_chain(
  adapter_dirs: results.map(&.descriptor.path), dest: FILTER_PATH,
  name: "amber-v2", version: FILTER_VERSION, base_model: MODEL,
  lora: Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 16),
  provenance: Llamero::Native::TrainingFilter::Provenance.new(
    methods: results.map(&.name), generator: "examples/train_amber_v2_adapter"),
  library: "amber", library_version: "2.0.0-dev",
  metrics: {
    "pairs"                   => pairs_count.to_f,
    "rank"                    => 8.0,
    "scale"                   => 1.0,
    "num_layers"              => 16.0,
    "learning_rate"           => 1e-4,
    "batch_size"              => 1.0,
    "unsupervised_iterations" => UNSUP_ITER.to_f,
    "supervised_iterations"   => SFT_ITER.to_f,
  },
)
runtime.close
puts "\nshipped #{filter.id} (chain of #{filter.manifest.stages.size}) -> #{FILTER_PATH}"
puts "trained on #{pairs_count} grounded pairs from #{CORPUS} using #{MODEL}"
