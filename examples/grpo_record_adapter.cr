# Phase 4 — GRPO (group-relative policy optimization), validated on-device.
# Builds on the record task + rubric + WeightedDataset. Each round: sample K
# completions per training prompt, score with the rubric, compute group-relative
# advantages (reward - group mean)/std, and do the advantage-weighted policy
# update (reinforce above-average completions, SUPPRESS below-average ones —
# this is what distinguishes GRPO from the keep-best practice loop). Proof: the
# held-out rubric rises across rounds on specs never trained on.
#
#   crystal run examples/grpo_record_adapter.cr
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"

record Spec, name : String, fields : Array({String, String})

def fieldlist(s : Spec) : String
  s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")
end

def instr(s : Spec) : String
  "Write a Crystal record named #{s.name} with fields #{fieldlist(s)}. Output only the record."
end

def good(s : Spec) : String
  "record #{s.name}, #{fieldlist(s)}"
end

TRAIN = [
  Spec.new("Point", [{"x", "Int32"}, {"y", "Int32"}]),
  Spec.new("User", [{"name", "String"}, {"age", "Int32"}]),
  Spec.new("Color", [{"r", "Int32"}, {"g", "Int32"}, {"b", "Int32"}]),
  Spec.new("Money", [{"amount", "Float64"}, {"currency", "String"}]),
  Spec.new("Range", [{"min", "Int32"}, {"max", "Int32"}]),
  Spec.new("Vec3", [{"x", "Float64"}, {"y", "Float64"}, {"z", "Float64"}]),
]
HOLDOUT = [
  Spec.new("Book", [{"title", "String"}, {"pages", "Int32"}]),
  Spec.new("Coord", [{"lat", "Float64"}, {"lng", "Float64"}]),
  Spec.new("Session", [{"id", "String"}, {"active", "Bool"}]),
  Spec.new("Rect", [{"w", "Int32"}, {"h", "Int32"}]),
  Spec.new("Tag", [{"label", "String"}]),
]

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model

rubric = Llamero::Native::Rubric.new(
  Llamero::Native::CrystalCompileReward.new,
  Llamero::Native::CrystalFormatReward.new,
)
stack = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("grpo-records")])

holdout_score = ->do
  total = 0.0
  HOLDOUT.each do |s|
    gen = Llamero::Native::RL.extract_code(session.chat([Llamero::Message.user(instr(s))], max_tokens: 48).content)
    score, _ = rubric.score("", gen)
    total += score
  end
  (total / HOLDOUT.size).round(3)
end

rounds = (ENV["ROUNDS"]?.try(&.to_i?) || 2)
samples = (ENV["SAMPLES"]?.try(&.to_i?) || 6)

base = holdout_score.call
puts "baseline held-out rubric: #{base}"
puts "GRPO: #{rounds} rounds x #{samples} samples; #{TRAIN.size} train / #{HOLDOUT.size} HELD-OUT specs"

# ON-POLICY: each round trains only on the CURRENT round's samples (plus a tiny
# ground-truth anchor), not a growing buffer of stale negatives — without a KL
# anchor in the loss, accumulating stale advantages lets the policy run away.
seed = TRAIN.first(2).map { |s| {instr(s), good(s), 1.0} }
results = [] of {Int32, Int32, Float64}

rounds.times do |r|
  buffer = seed.dup
  TRAIN.each do |s|
    prompt = instr(s)
    comps = [] of String
    rewards = [] of Float64
    samples.times do
      gen = Llamero::Native::RL.extract_code(session.chat([Llamero::Message.user(prompt)], temperature: 0.9_f32, max_tokens: 48).content)
      score, _ = rubric.score("", gen)
      comps << gen
      rewards << score
    end
    mean = rewards.sum / rewards.size
    variance = rewards.sum { |x| (x - mean) ** 2 } / rewards.size
    std = Math.sqrt(variance)
    next if std < 1e-6 # whole group scored the same -> no advantage signal
    comps.each_with_index do |gen, i|
      next if gen.blank?
      advantage = (rewards[i] - mean) / (std + 1e-4)
      buffer << {prompt, gen, advantage}
    end
  end

  session.deactivate_adapters
  wds = Llamero::Native::WeightedDataset.new
  buffer.each { |prompt, completion, weight| wds.add(prompt, completion, weight) }
  config = Llamero::Native::AdapterTrainingConfig.new
  config.iterations = (ENV["ITERS"]?.try(&.to_i?) || 60)
  config.num_layers = 8
  config.learning_rate = (ENV["LR"]?.try(&.to_f?) || 5e-6)
  config.steps_per_report = 1000
  session.train_adapter("grpo-records", wds, config)
  session.activate_adapters(stack)

  ho = holdout_score.call
  results << {r, buffer.size, ho}
  puts "round #{r}: buffer=#{buffer.size} weighted samples, held-out=#{ho}"
end

final = results.last[2]
runtime.close
puts "\n=== GRPO results ==="
puts "held-out rubric: baseline #{base} -> final #{final}"
if final > base
  puts "GRPO VALIDATED — held-out rose #{base} -> #{final} on unseen specs via advantage-weighted updates"
else
  abort "GRPO DID NOT IMPROVE held-out (#{base} -> #{final}); tune ROUNDS/SAMPLES/ITERS"
end
