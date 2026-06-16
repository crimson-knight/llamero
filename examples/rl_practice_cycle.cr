# A working reinforcement-learning cycle (expert iteration / rejection sampling)
# validated on-device: the model practices writing Crystal `record`s for specs it
# has NEVER trained on, each attempt judged by static-analysis tools — does it
# COMPILE (`crystal build --no-codegen`, "no errors") and is it FORMAT-CLEAN
# (`crystal tool format --check`, "no changes"). The best attempts become
# training data; the held-out score rising across rounds is the validation.
#
#   crystal run examples/rl_practice_cycle.cr
#   ROUNDS=4 SAMPLES=6 crystal run examples/rl_practice_cycle.cr
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"

record Spec, name : String, fields : Array({String, String})

def prompt_for(spec : Spec) : String
  list = spec.fields.map { |n, t| "#{n} : #{t}" }.join(", ")
  "Write a Crystal record named #{spec.name} with fields #{list}."
end

def truth_for(spec : Spec) : String
  list = spec.fields.map { |n, t| "#{n} : #{t}" }.join(", ")
  "record #{spec.name}, #{list}"
end

TRAIN = [
  Spec.new("Point", [{"x", "Int32"}, {"y", "Int32"}]),
  Spec.new("User", [{"name", "String"}, {"age", "Int32"}]),
  Spec.new("Color", [{"r", "Int32"}, {"g", "Int32"}, {"b", "Int32"}]),
  Spec.new("Money", [{"amount", "Float64"}, {"currency", "String"}]),
  Spec.new("Flag", [{"enabled", "Bool"}]),
  Spec.new("Range", [{"min", "Int32"}, {"max", "Int32"}]),
  Spec.new("Article", [{"title", "String"}, {"words", "Int32"}]),
  Spec.new("Vec3", [{"x", "Float64"}, {"y", "Float64"}, {"z", "Float64"}]),
]
HOLDOUT = [
  Spec.new("Book", [{"title", "String"}, {"pages", "Int32"}]),
  Spec.new("Coord", [{"lat", "Float64"}, {"lng", "Float64"}]),
  Spec.new("Session", [{"id", "String"}, {"active", "Bool"}]),
  Spec.new("Rect", [{"w", "Int32"}, {"h", "Int32"}]),
  Spec.new("Tag", [{"label", "String"}]),
]

SYSTEM = "You write Crystal code. Output ONLY one Crystal `record` declaration and nothing else — no prose, no code fences. Example: record Point, x : Int32, y : Int32"

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found (build: cd native/llamero-mlx && ./build.sh)" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model

# Rubric: the two static-analysis tools the model must satisfy perfectly.
rubric = Llamero::Native::Rubric.new(
  Llamero::Native::CrystalCompileReward.new,   # "no errors"
  Llamero::Native::CrystalFormatReward.new,    # "no changes made"
)

# Warm the buffer with a few known-good examples (the kind ExampleGenerator
# produces) so the cycle has a format to refine — RL then generalizes to the
# unseen holdout specs.
seed = TRAIN.first(3).map { |s| {prompt_for(s), truth_for(s)} }

loop = Llamero::Native::PracticeLoop.new(
  session: session, rubric: rubric,
  train_prompts: TRAIN.map { |s| prompt_for(s) },
  holdout_prompts: HOLDOUT.map { |s| prompt_for(s) },
  adapter_name: "rl-records",
  system_prompt: SYSTEM,
)

rounds = (ENV["ROUNDS"]?.try(&.to_i?) || 3)
samples = (ENV["SAMPLES"]?.try(&.to_i?) || 5)
puts "RL cycle: #{rounds} rounds x #{samples} samples; #{TRAIN.size} train / #{HOLDOUT.size} HELD-OUT specs"
results = loop.run(rounds: rounds, samples: samples, temperature: 0.9_f32, max_tokens: 48, seed: seed)

base_score, base_bd = loop.baseline.not_nil!
puts "\n=== held-out generalization (greedy, on specs never trained on) ==="
puts "baseline   score=#{base_score}  #{base_bd}"
results.each do |r|
  puts "round #{r.round}    score=#{r.holdout_score}  #{r.holdout_breakdown}  (kept #{r.kept} for training)"
end

final = results.last.holdout_score
runtime.close
if final > base_score
  puts "\nRL CYCLE VALIDATED — held-out score rose #{base_score} -> #{final} on unseen specs"
else
  abort "\nRL CYCLE DID NOT IMPROVE held-out (#{base_score} -> #{final}); tune ROUNDS/SAMPLES or task"
end
