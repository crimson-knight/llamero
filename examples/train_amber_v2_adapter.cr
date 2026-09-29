# Train a versioned Amber V2 filter from the grounded SFT corpus. Held-out
# scoring is handled by scripts/eval_amber_grant_filter.cr so the same questions
# and compile/symbol gates run before and after training.
#
#   crystal-alpha run examples/train_amber_v2_adapter.cr -- [MODEL] [UNSUP_ITERS]
#     [SFT_ITERS] [FILTER_VERSION] [FILTER_PATH] [MODEL_PATH]
#     [full-sequence|completion-only] [INITIAL_FILTER_PATH]
require "../src/llamero"
require "json"
require "file_utils"

class AmberV2TrainingRow
  include JSON::Serializable

  property kind : String = ""
  property completion : String = ""
end

class AmberGrantTrainingPair
  include JSON::Serializable

  property prompt : String = ""
  property completion : String = ""
end

PINNED_MODEL        = "mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2"
MODEL               = ARGV[0]? || PINNED_MODEL
UNSUP_ITER          = (ARGV[1]? || "200").to_i
SFT_ITER            = (ARGV[2]? || "400").to_i
FILTER_VERSION      = ARGV[3]? || "0.2.1"
FILTER_PATH         = Path[ARGV[4]? || Path.home.join(".llamero", "filters", "amber-v2-#{FILTER_VERSION}.filter").to_s].expand
MODEL_PATH          = Path[ARGV[5]? || Path.home.join(".llamero", "models", "mlx-community--gemma-3-4b-it-4bit").to_s].expand
LOSS_MODE           = ARGV[6]? || "full-sequence"
INITIAL_FILTER_PATH = ARGV[7]?
unless ["full-sequence", "completion-only"].includes?(LOSS_MODE)
  abort "loss mode must be full-sequence or completion-only; got #{LOSS_MODE}"
end
COMPLETION_ONLY_LOSS = LOSS_MODE == "completion-only"
INITIAL_FILTER       = if initial_filter_path = INITIAL_FILTER_PATH
                         filter = Llamero::Native::TrainingFilter.load(initial_filter_path)
                         list_of_expected_base_models = [MODEL, MODEL.sub(/@[^@]+$/, "")]
                         abort "initial filter base mismatch: #{filter.manifest.base_model}" unless list_of_expected_base_models.includes?(filter.manifest.base_model)
                         abort "initial filter must be Amber 0.1.0; got #{filter.id}" unless filter.id == "amber-v2@0.1.0"
                         unless filter.manifest.chain? && filter.manifest.stages.size == 2
                           abort "initial Amber 0.1.0 filter must contain its two-stage chain"
                         end
                         unless filter.manifest.lora.rank == 8 && filter.manifest.lora.num_layers == 16
                           abort "initial Amber filter must use rank 8 across 16 layers"
                         end
                         filter
                       end
CORPUS      = Path[__DIR__].parent.join("training_data", "amber", "amber_v2_sft.jsonl")
GRANT_PAIRS = Path[__DIR__].parent.join("training_data", "amber", "grant_tenancy_rawsql_pairs.jsonl")
PROBE_DIR   = Path[__DIR__].parent.join(".crystal-cache", "round3b", "#{FILTER_VERSION}-grant-loss-probe")
SYSTEM      = "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."

abort "refusing to overwrite an existing filter: #{FILTER_PATH}" if File.exists?(FILTER_PATH)
abort "verified model directory is missing: #{MODEL_PATH}" unless Dir.exists?(MODEL_PATH)

bridge = Llamero::Native::MLXBridge.try_load
abort "no MLX bridge — build native/llamero-mlx (./build.sh) first" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, model_path: MODEL_PATH.to_s, bridge: bridge)
session = runtime.start_session
if initial_filter = INITIAL_FILTER
  # Fuse every seed stage permanently: the new stages train on this base.
  session.activate_filter(initial_filter, cumulative: true)
  puts "fused initial filter #{initial_filter.id} before Grant training"
else
  session.load_model
end

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
abort "Grant pair corpus missing: #{GRANT_PAIRS}" unless File.exists?(GRANT_PAIRS)
probe_template = Llamero::Native::TrainingDataset.template_from(MODEL_PATH.to_s) ||
                 abort("pinned model chat template could not be resolved")
probe_ds = Llamero::Native::TrainingDataset.new(system_prompt: SYSTEM)
probe_ds.use_template(probe_template, "model-chat-template-loss-probe")
File.each_line(GRANT_PAIRS.to_s) do |line|
  next if line.blank?
  pair = AmberGrantTrainingPair.from_json(line)
  probe_ds.add(pair.prompt, pair.completion)
end
abort "Grant loss probe needs exactly 84 pairs; found #{probe_ds.size}" unless probe_ds.size == 84
probe_dir = probe_ds.write(PROBE_DIR, valid_fraction: 0.0)
puts "Grant loss probe: #{probe_ds.size} rows, template=#{probe_ds.template_source}, path=#{probe_dir}"

def cfg(iters, loss_probe_path : String, completion_only_loss : Bool)
  c = Llamero::Native::AdapterTrainingConfig.new
  c.iterations = iters
  c.rank = 8
  c.scale = 1.0
  c.num_layers = 16
  c.batch_size = 1
  c.learning_rate = 1e-4
  c.steps_per_report = 50
  c.loss_probe_data_path = loss_probe_path
  c.completion_only_loss = completion_only_loss
  c
end

pipeline = Llamero::Native::StagedPipeline.new(session, "amber-v2-#{FILTER_VERSION}")
pipeline.stage("syntax") do
  descriptor = session.train_adapter(
    "amber-v2-#{FILTER_VERSION}-syntax", text_ds,
    cfg(UNSUP_ITER, probe_dir.to_s, false)
  ) do |progress|
    puts "  syntax iteration=#{progress.iteration} loss=#{progress.loss}"
  end
  summary = session.last_training || raise "syntax stage completed without a training summary"
  puts "  syntax final_loss=#{summary.final_loss} Grant loss=#{summary.grant_loss_before} -> #{summary.grant_loss_after} rows=#{summary.grant_probe_rows}"
  descriptor
end
pipeline.stage("usage") do
  usage_config = cfg(SFT_ITER, probe_dir.to_s, COMPLETION_ONLY_LOSS)
  descriptor = session.train_adapter(
    "amber-v2-#{FILTER_VERSION}-usage", sft_ds, usage_config
  ) do |progress|
    puts "  usage iteration=#{progress.iteration} loss=#{progress.loss}"
  end
  summary = session.last_training || raise "usage stage completed without a training summary"
  puts "  usage template=#{sft_ds.template_source} completion_only=#{summary.completion_only_loss} final_loss=#{summary.final_loss} Grant loss=#{summary.grant_loss_before} -> #{summary.grant_loss_after} rows=#{summary.grant_probe_rows}"
  descriptor
end
puts "\n=== training (unsupervised #{UNSUP_ITER} -> SFT #{SFT_ITER}, fuse-forward; loss=#{LOSS_MODE}) ==="
results = pipeline.run { |i, name| puts "  stage #{i}: #{name} (#{Time.local})" }

# Ship the composed adapter as a distributable chain filter. When a working
# Amber filter seeded training, include its stages so the result is standalone.
list_of_adapter_dirs = [] of String
list_of_provenance_methods = [] of String
if initial_filter = INITIAL_FILTER
  list_of_adapter_dirs.concat(initial_filter.stage_dirs.map(&.to_s))
  list_of_provenance_methods << "fused-base-#{initial_filter.id}"
end
list_of_adapter_dirs.concat(results.map(&.descriptor.path))
list_of_provenance_methods.concat(results.map(&.name))
FileUtils.mkdir_p(FILTER_PATH.parent.to_s)
filter = Llamero::Native::TrainingFilter.pack_chain(
  adapter_dirs: list_of_adapter_dirs, dest: FILTER_PATH,
  name: "amber-v2", version: FILTER_VERSION, base_model: MODEL,
  lora: Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 16),
  provenance: Llamero::Native::TrainingFilter::Provenance.new(
    methods: list_of_provenance_methods, generator: "examples/train_amber_v2_adapter"),
  library: "amber", library_version: "2.0.0-dev",
  metrics: {
    "pairs"                   => pairs_count.to_f,
    "rank"                    => 8.0,
    "scale"                   => 1.0,
    "num_layers"              => 16.0,
    "learning_rate"           => 1e-4,
    "batch_size"              => 1.0,
    "completion_only_loss"    => COMPLETION_ONLY_LOSS ? 1.0 : 0.0,
    "unsupervised_iterations" => UNSUP_ITER.to_f,
    "supervised_iterations"   => SFT_ITER.to_f,
  },
)
runtime.close
puts "\nshipped #{filter.id} (chain of #{filter.manifest.stages.size}) -> #{FILTER_PATH}"
puts "trained on #{pairs_count} grounded pairs from #{CORPUS} using #{MODEL}"
