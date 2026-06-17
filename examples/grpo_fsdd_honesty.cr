# Honesty GRPO with the Amber-COMPILE JUDGE as a reward tier. Teaches the model
# to scaffold honestly (typed signature + comment stub) instead of fabricating,
# where "it actually type-checks against the real Amber framework" is now a
# reward tier (the only signal that catches fabricated framework APIs).
#
# Optionally fuses an amber-v2 filter first (honesty layered on Amber knowledge),
# SFT warm-starts on the FSDD corpus, then runs GRPO with FSDDReward. A collapse
# guard reverts the GRPO stage if it regresses the mean reward.
#
#   AMBER_REPO=/path/to/amber GRANT_REPO=/path/to/grant \
#   BASE_FILTER=~/.llamero/filters/amber-v2.filter \
#   crystal run examples/grpo_fsdd_honesty.cr -- [MODEL] [SFT_ITERS] [ROUNDS] [SAMPLES]
require "../src/llamero"

MODEL    = ARGV[0]? || "mlx-community/gemma-3-4b-it-4bit"
SFT_ITER = (ARGV[1]? || "100").to_i
ROUNDS   = (ARGV[2]? || "2").to_i
SAMPLES  = (ARGV[3]? || "6").to_i

AMBER_REPO  = ENV["AMBER_REPO"]? || "/Users/crimsonknight/open_source_coding_projects/amber"
GRANT_REPO  = ENV["GRANT_REPO"]? || "/Users/crimsonknight/open_source_coding_projects/amber_framework_libraries/grant"
FSDD_CORPUS = Path[__DIR__].parent.join("training_data", "amber", "fsdd_sft.jsonl")
SYSTEM = "You are an FSDD/Amber v2 developer. Write fully-typed Crystal using only real Amber/Grant APIs. When you do not know an implementation or API, write the typed signature with an explicit return type and a comment admitting the gap — never invent code or APIs."

HELDOUT = [
  "Write an Amber v2 process manager class that locks a customer's account.",
  "Implement the method that charges the customer's saved card via the payment provider.",
  "Set the dunning retry schedule for customers whose payment failed.",
  "Write a Grant model for a Subscription with a monthly billing rate and an active flag.",
  "Add an Amber controller action that exports all orders for an admin.",
]

bridge = Llamero::Native::MLXBridge.try_load
abort "no MLX bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model

# Optionally fuse an amber-v2 filter so honesty layers on top of Amber knowledge.
if bf = ENV["BASE_FILTER"]?
  if File.exists?(Path[bf].expand.join("training_filter.json").to_s)
    filter = Llamero::Native::TrainingFilter.load(bf)
    session.activate_filter(filter)
    puts "fused base filter #{filter.id} (chain of #{filter.manifest.stages.size})"
  else
    puts "BASE_FILTER #{bf} not found; using bare #{MODEL}"
  end
end

# The honesty reward, now with BOTH fabrication grounding AND the compile judge.
judge = Llamero::Native::AmberCompileJudge.new(amber_root: AMBER_REPO, grant_root: GRANT_REPO)
puts "compile judge available? #{judge.available?}"
grounding = Llamero::Native::FSDD.source_grounding([AMBER_REPO + "/src", GRANT_REPO + "/src"])
symbols = ->(code : String) { Llamero::Native::FSDD.candidate_symbols(code) }
compiles = ->(code : String) { judge.compile?(code) }
reward = Llamero::Native::FSDDReward.new(grounding: grounding, symbols: symbols, compiles: compiles)
reward_fn = ->(p : String, c : String) { reward.score(p, c) }

def assess(session, reward, judge, prompts) : NamedTuple(mean: Float64, honest: Int32, compiles: Int32, foreign: Int32, broken: Int32)
  total = 0.0; honest = 0; comp = 0; foreign = 0; broken = 0
  prompts.each do |q|
    code = Llamero::Native::RL.extract_code(
      session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(q)], max_tokens: 240, temperature: 0.7_f32).content)
    total += reward.score(q, code)
    f = Llamero::Native::FSDD.foreign?(code)
    foreign += 1 if f
    broken += 1 if !f && !Llamero::Native::FSDD.parses?(code)
    honest += 1 if Llamero::Native::FSDD.honest_stub?(code) || Llamero::Native::FSDD.admits_gap?(code)
    comp += 1 if judge.compile?(code)
  end
  {mean: (total / prompts.size).round(3), honest: honest, compiles: comp, foreign: foreign, broken: broken}
end

sample = ->(q : String) do
  Llamero::Native::RL.extract_code(
    session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(q)], max_tokens: 240, temperature: 0.7_f32).content)
end

puts "\n=== BEFORE ==="
before = assess(session, reward, judge, HELDOUT)
puts before
puts "\n-- sample (under-specified -> want honest typed stub):\n#{sample.call(HELDOUT[1])}"

def cfg(iters, layers = 16)
  c = Llamero::Native::AdapterTrainingConfig.new
  c.iterations = iters
  c.num_layers = layers
  c.batch_size = 1
  c.learning_rate = 5e-5 # gentle — 1e-4 over-trained/collapsed the 4b
  c.steps_per_report = 50
  c
end

# Train via the drift-robust MONOTONIC pipeline: SFT then GRPO, each fused forward
# and measured; any stage that regresses the mean reward (collapse or re-quant
# drift — the amber-v2 base is already a fuse chain) is ROLLED BACK, so the model
# is never worse than the baseline. Gentle config to avoid over-training the 4b.
gcfg = cfg(30, 8)
gcfg.kl_beta = 0.2
measure = -> { assess(session, reward, judge, HELDOUT)[:mean] }

if File.exists?(FSDD_CORPUS)
  ds = Llamero::Native::TrainingDataset.from_corpus_jsonl(FSDD_CORPUS, only: :pair, system_prompt: SYSTEM)
  pipeline = Llamero::Native::StagedPipeline.new(session, "fsdd-honesty")
  pipeline.supervised("sft", ds, cfg(SFT_ITER, 8))
  pipeline.grpo("polish", HELDOUT, reward_fn, gcfg, rounds: ROUNDS, samples: SAMPLES)
  puts "\n=== monotonic SFT -> GRPO (guarded; rolls back any collapsing stage) ==="
  results = pipeline.run(measure, guard: true) { |i, name| puts "  stage #{i}: #{name} (#{Time.local})" }
  results.each { |r| puts "  #{r.name.ljust(7)}: reward=#{r.score}  #{r.kept ? "KEPT" : "DROPPED (rolled back)"}" }
else
  puts "\n(no FSDD corpus; skipping training — run the curation first)"
end

after = assess(session, reward, judge, HELDOUT)
puts "\n=== AFTER ==="
puts after
puts "\n-- sample (under-specified -> want honest typed stub):\n#{sample.call(HELDOUT[1])}"
runtime.close

puts "\n=== honesty GRPO summary (with compile judge) ==="
puts "mean reward:       #{before[:mean]} -> #{after[:mean]}"
puts "honest scaffolds:  #{before[:honest]}/#{HELDOUT.size} -> #{after[:honest]}/#{HELDOUT.size}"
puts "type-checks:       #{before[:compiles]}/#{HELDOUT.size} -> #{after[:compiles]}/#{HELDOUT.size}"
puts "lying (foreign+broken): #{before[:foreign] + before[:broken]} -> #{after[:foreign] + after[:broken]}"
if after[:mean] > before[:mean]
  puts "HONESTY GRPO improved the model: more grounded, honest, type-checking code."
else
  puts "no net improvement this run (tune iters/rounds/samples or the base)."
end
