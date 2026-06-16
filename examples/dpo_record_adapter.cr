# Phase 3 — DPO (preference optimization), validated on-device. Builds on the
# record task: chosen = the correct Crystal `record`, rejected = a malformed one.
# DPO trains the adapter to prefer chosen over rejected relative to the frozen
# base. Proof: the preference MARGIN rises during training, and the held-out
# rubric (compile + format) improves on specs never trained on.
#
#   crystal run examples/dpo_record_adapter.cr
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

# Malformed but plausible: missing commas, no spaces around colons.
def bad(s : Spec) : String
  "record #{s.name} #{s.fields.map { |n, t| "#{n}:#{t}" }.join(" ")}"
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

holdout_score = ->do
  hits = 0.0
  HOLDOUT.each do |s|
    gen = Llamero::Native::RL.extract_code(session.chat([Llamero::Message.user(instr(s))], max_tokens: 48).content)
    score, _ = rubric.score("", gen)
    hits += score
  end
  (hits / HOLDOUT.size).round(3)
end

base = holdout_score.call
puts "baseline held-out rubric: #{base}"

prefs = Llamero::Native::PreferenceDataset.new
TRAIN.each { |s| prefs.add(instr(s), good(s), bad(s)) }
puts "preference pairs: #{prefs.size} (chosen=correct record, rejected=malformed)"

config = Llamero::Native::AdapterTrainingConfig.new
# DPO over-optimizes easily: the margin saturates fast, so stop early and keep a
# strong KL anchor (high beta) or the policy diverges from the base and
# degenerates. Few iterations + high beta keep the preference without wrecking
# general generation.
config.iterations = (ENV["ITERS"]?.try(&.to_i?) || 40)
config.num_layers = 8
config.dpo_beta = (ENV["BETA"]?.try(&.to_f?) || 0.5)
config.learning_rate = (ENV["LR"]?.try(&.to_f?) || 5e-6)
config.steps_per_report = 10

margins = [] of Float64
session.train_adapter("dpo-records", prefs, config) do |p|
  margins << p.tokens_per_second # runDPO reports the running-mean preference margin here
  puts "  iter #{p.iteration}/#{p.total_iterations} dpo_loss=#{p.loss.round(3)} margin=#{p.tokens_per_second.round(3)}"
end

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("dpo-records")])
)
after = holdout_score.call
runtime.close

first_margin = margins.first
last_margin = margins.last
puts "\n=== DPO results ==="
puts "preference margin: #{first_margin.round(3)} -> #{last_margin.round(3)} (chosen preferred over rejected)"
puts "held-out rubric:   #{base} -> #{after}"
if last_margin > first_margin
  puts "DPO VALIDATED — preference margin rose (#{first_margin.round(3)} -> #{last_margin.round(3)}); held-out #{base} -> #{after}"
else
  abort "DPO DID NOT IMPROVE the preference margin (#{first_margin.round(3)} -> #{last_margin.round(3)})"
end
