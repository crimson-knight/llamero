# Overnight: train an Amber v2 adapter on the GROUNDED corpus (curated by the
# Phase A agent fan-out, each pair gated against the real amber 2.0.0-dev source),
# ship it as a distributable filter, and print before/after generations on
# held-out v2 questions so you can eyeball what it learned.
#
#   crystal run examples/train_amber_v2_adapter.cr -- [MODEL] [UNSUP_ITERS] [SFT_ITERS]
#   # defaults: gemma-3-1b-it-4bit, 200, 400
#
# For a desktop/server overnight run, gemma-3-4b-it-4bit + higher iters is a good
# next step once the 1b run looks sane.
require "../src/llamero"
require "json"
require "file_utils"

MODEL      = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
UNSUP_ITER = (ARGV[1]? || "200").to_i
SFT_ITER   = (ARGV[2]? || "400").to_i
CORPUS     = Path[__DIR__].parent.join("training_data", "amber", "amber_v2_sft.jsonl")
SYSTEM     = "You are an expert Amber v2 (Crystal web framework) developer. Answer with correct, idiomatic Amber v2 code."

# Held-out v2 questions (NOT verbatim in the corpus) — probe whether training
# instilled the real v2 DSLs vs the base model's Amber-v1/Rails memory.
HELDOUT = [
  "How do I define a GET route mapping /users to UsersController#index in Amber?",
  "Write an Amber WebSocket channel that broadcasts a welcome message after a client joins.",
  "Define an Amber schema with a required email string field and validate its format.",
  "Create an Amber background job that retries up to 3 times and runs after a delay.",
  "Write an Amber controller with a before_action that authenticates the user.",
]

bridge = Llamero::Native::MLXBridge.try_load
abort "no MLX bridge — build native/llamero-mlx (./build.sh) first" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model

ask = ->(q : String) do
  session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(q)], max_tokens: 220).content.strip
end

puts "=== BEFORE (bare #{MODEL}) ==="
before = HELDOUT.map { |q| {q, ask.call(q)} }
before.each { |q, a| puts "\nQ: #{q}\n#{a}" }

# Build datasets: unsupervised on the completions (absorb v2 syntax/vocab), then
# SFT on the instruction->code pairs (idiomatic usage + format).
abort "corpus missing: #{CORPUS}" unless File.exists?(CORPUS)
completions = [] of String
pairs_count = 0
File.each_line(CORPUS.to_s) do |line|
  next if line.blank?
  row = JSON.parse(line)
  if c = row["completion"]?.try(&.as_s?)
    completions << c
    pairs_count += 1
  end
end
puts "\ncorpus: #{pairs_count} grounded Amber v2 pairs from #{CORPUS}"

text_ds = Llamero::Native::TrainingDataset.from_text(completions)
sft_ds = Llamero::Native::TrainingDataset.from_corpus_jsonl(CORPUS, only: :pair, system_prompt: SYSTEM)

def cfg(iters)
  c = Llamero::Native::AdapterTrainingConfig.new
  c.iterations = iters
  c.num_layers = 16
  c.batch_size = 1
  c.learning_rate = 1e-4
  c.steps_per_report = 50
  c
end

pipeline = Llamero::Native::StagedPipeline.new(session, "amber-v2")
pipeline.unsupervised("syntax", text_ds, cfg(UNSUP_ITER))
pipeline.supervised("usage", sft_ds, cfg(SFT_ITER))
puts "\n=== training (unsupervised #{UNSUP_ITER} -> SFT #{SFT_ITER}, fuse-forward) ==="
results = pipeline.run { |i, name| puts "  stage #{i}: #{name} (#{Time.local})" }

puts "\n=== AFTER (amber-v2 adapter) ==="
after = HELDOUT.map { |q| {q, ask.call(q)} }
after.each { |q, a| puts "\nQ: #{q}\n#{a}" }

# Ship the composed adapter as a distributable chain filter.
dist = Path[Dir.tempdir].join("amber-v2-dist-#{Random::Secure.hex(4)}")
pkg = dist.join("amber-v2.filter")
filter = Llamero::Native::TrainingFilter.pack_chain(
  adapter_dirs: results.map(&.descriptor.path), dest: pkg,
  name: "amber-v2", version: "0.1.0", base_model: MODEL,
  lora: Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 16),
  provenance: Llamero::Native::TrainingFilter::Provenance.new(
    methods: results.map(&.name), generator: "examples/train_amber_v2_adapter"),
  library: "amber", library_version: "2.0.0-dev",
  metrics: {"pairs" => pairs_count.to_f},
)
runtime.close
puts "\nshipped #{filter.id} (chain of #{filter.manifest.stages.size}) -> #{pkg}"
puts "trained on #{pairs_count} grounded pairs; eyeball BEFORE vs AFTER above for v2 DSL adoption."
puts "(filter package left at #{pkg}; copy it to $LLAMERO_HOME/filters to install)"
