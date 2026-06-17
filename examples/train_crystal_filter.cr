# Phase 1d: train + ship the open-source Crystal-language filter on the corpus
# built from the stdlib doc catalog (1541 examples) + 58 version facts. Full
# ladder via the drift-robust StagedPipeline guard (unsup -> SFT -> GRPO), reward
# = compile + format (pure Crystal verifies standalone), pack crystal@1.20.filter,
# validate held-out, append metrics to the progress log.
#
#   crystal run examples/train_crystal_filter.cr -- [MODEL] [UNSUP] [SFT] [ROUNDS] [SAMPLES]
require "../src/llamero"
require "file_utils"

MODEL  = ARGV[0]? || "mlx-community/gemma-3-4b-it-4bit"
UNSUP  = (ARGV[1]? || "150").to_i
SFTI   = (ARGV[2]? || "500").to_i
ROUNDS = (ARGV[3]? || "2").to_i
SAMPLES = (ARGV[4]? || "6").to_i

DIR = Path[__DIR__].parent.join("training_data", "crystal")
SFT_CORPUS = DIR.join("crystal_sft.jsonl")
TEXT_CORPUS = DIR.join("stdlib_text.jsonl")
SYSTEM = "You write idiomatic Crystal. Output ONLY valid Crystal code, no prose."

# Held-out pure-Crystal tasks (no framework) — scored by compile + format.
HELDOUT = [
  "Write a Crystal method `unique_sorted(values : Array(Int32)) : Array(Int32)` returning the sorted unique values.",
  "Write a Crystal record `Point` with `x` and `y` Int32 fields.",
  "Write a Crystal method that reads a file at a path and returns its lines as an Array(String).",
  "Write a Crystal enum `Direction` with North, South, East, West and a method `opposite : Direction`.",
  "Write a Crystal method that counts word frequencies in a string and returns a Hash(String, Int32).",
  "Write a Crystal method `safe_div(a : Int32, b : Int32) : Int32?` returning nil on divide-by-zero.",
]

bridge = Llamero::Native::MLXBridge.try_load
abort "no MLX bridge" unless bridge
abort "corpus missing — run build_crystal_corpus.cr" unless File.exists?(SFT_CORPUS)
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model

rubric = Llamero::Native::Rubric.new(Llamero::Native::CrystalCompileReward.new, Llamero::Native::CrystalFormatReward.new)
reward_fn = ->(_p : String, c : String) { rubric.score("", Llamero::Native::RL.extract_code(c))[0] }

def assess(session, rubric, prompts) : NamedTuple(mean: Float64, compiles: Int32)
  total = 0.0; comp = 0
  prompts.each do |q|
    code = Llamero::Native::RL.extract_code(
      session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(q)], max_tokens: 200, temperature: 0.6_f32).content)
    s = rubric.score("", code)
    total += s[0]
    comp += 1 if s[1]["compiles"] == 1.0
  end
  {mean: (total / prompts.size).round(3), compiles: comp}
end

def cfg(iters, layers = 16)
  c = Llamero::Native::AdapterTrainingConfig.new
  c.iterations = iters; c.num_layers = layers; c.batch_size = 1
  c.learning_rate = 5e-5; c.steps_per_report = 100
  c
end

before = assess(session, rubric, HELDOUT)
puts "BEFORE: #{before}"

text = Llamero::Native::TrainingDataset.from_corpus_jsonl(TEXT_CORPUS, only: :text)
sft = Llamero::Native::TrainingDataset.from_corpus_jsonl(SFT_CORPUS, only: :pair, system_prompt: SYSTEM)

pipeline = Llamero::Native::StagedPipeline.new(session, "crystal")
pipeline.unsupervised("stdlib", text, cfg(UNSUP))
pipeline.supervised("usage", sft, cfg(SFTI))
pipeline.grpo("polish", HELDOUT, reward_fn, cfg(40), rounds: ROUNDS, samples: SAMPLES)

measure = -> { assess(session, rubric, HELDOUT)[:mean] }
puts "=== training crystal filter (unsup #{UNSUP} -> SFT #{SFTI} -> GRPO, guarded) ==="
results = pipeline.run(measure, guard: true) { |i, name| puts "  stage #{i}: #{name} (#{Time.local})" }
results.each { |r| puts "  #{r.name.ljust(7)}: reward=#{r.score} #{r.kept ? "KEPT" : "DROPPED"}" }

after = assess(session, rubric, HELDOUT)
puts "AFTER: #{after}"

# Ship the composed base as crystal@1.20.filter (a fuse-forward chain of kept stages).
kept = results.select(&.kept)
if kept.empty?
  puts "no stage kept; nothing to ship"
else
  dist = Path[Dir.tempdir].join("crystal-filter-#{Random::Secure.hex(4)}")
  pkg = dist.join("crystal.filter")
  filter = Llamero::Native::TrainingFilter.pack_chain(
    adapter_dirs: kept.map(&.descriptor.path), dest: pkg,
    name: "crystal", version: "1.20.0", base_model: MODEL,
    lora: Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 16),
    provenance: Llamero::Native::TrainingFilter::Provenance.new(methods: kept.map(&.name), generator: "examples/train_crystal_filter"),
    library: "crystal", library_version: "1.20.0",
    metrics: {"compile_before" => before[:compiles].to_f, "compile_after" => after[:compiles].to_f})
  dest = Path.home.join(".llamero", "filters", "crystal.filter")
  Dir.mkdir_p(dest.parent.to_s)
  FileUtils.rm_rf(dest.to_s) if Dir.exists?(dest.to_s)
  FileUtils.cp_r(pkg.to_s, dest.to_s)
  puts "shipped #{filter.id} (chain of #{filter.manifest.stages.size}) -> #{dest}"
end
runtime.close

# Log metrics for the progress chart.
metrics_dir = Path[__DIR__].parent.join("training_data", "metrics")
if Dir.exists?(metrics_dir.to_s)
  stages = [{name: "baseline", reward: before[:mean]}]
  results.each { |r| stages << {name: r.kept ? r.name : "#{r.name} (DROPPED)", reward: (r.score || 0.0)} }
  stages << {name: "final", reward: after[:mean]}
  rec = {run: "crystal@1.20 (#{MODEL.split('/').last})", base: MODEL, guard: true, judge: true,
         stages: stages, behavior: {honest: [0, 0], compiles: [before[:compiles], after[:compiles]], lying: [0, 0]},
         outcome: after[:mean] > before[:mean] ? "improved" : "no net gain"}
  File.open(metrics_dir.join("crystal_runs.jsonl").to_s, "a") { |io| io.puts(rec.to_json) }
end

puts "\n=== Crystal filter summary ==="
puts "compile rate: #{before[:compiles]}/#{HELDOUT.size} -> #{after[:compiles]}/#{HELDOUT.size}"
puts "mean reward:  #{before[:mean]} -> #{after[:mean]}"
