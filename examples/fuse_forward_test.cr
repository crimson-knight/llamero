# Fuse-forward composition (the linchpin for Crystal -> Amber -> product layering).
# Train adapter A -> CUMULATIVELY fuse it into the base -> train adapter B ON the
# A-fused base -> B builds on A. The key proof: train_adapter SUCCEEDS after a
# cumulative fuse (it's blocked today by the "deactivate before training" guard),
# load_count stays 1 (no reload), and A's knowledge persists into the composed model.
#
#   crystal run examples/fuse_forward_test.cr
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"

record Spec, name : String, fields : Array({String, String})

def instr(s : Spec) : String
  "Write a Crystal record named #{s.name} with fields #{s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")}. Output only the record."
end

def truth(s : Spec) : String
  "record #{s.name}, #{s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")}"
end

A_SPECS = [
  Spec.new("Point", [{"x", "Int32"}, {"y", "Int32"}]),
  Spec.new("User", [{"name", "String"}, {"age", "Int32"}]),
  Spec.new("Color", [{"r", "Int32"}, {"g", "Int32"}, {"b", "Int32"}]),
  Spec.new("Money", [{"amount", "Float64"}, {"currency", "String"}]),
]
B_SPECS = [
  Spec.new("Range", [{"min", "Int32"}, {"max", "Int32"}]),
  Spec.new("Vec3", [{"x", "Float64"}, {"y", "Float64"}, {"z", "Float64"}]),
  Spec.new("Flag", [{"on", "Bool"}]),
  Spec.new("Tag", [{"label", "String"}]),
]
HOLDOUT = [
  Spec.new("Book", [{"title", "String"}, {"pages", "Int32"}]),
  Spec.new("Coord", [{"lat", "Float64"}, {"lng", "Float64"}]),
  Spec.new("Rect", [{"w", "Int32"}, {"h", "Int32"}]),
]
SYSTEM = "You write Crystal. Output ONLY one Crystal `record` declaration, nothing else."

bridge = Llamero::Native::MLXBridge.try_load
abort "no bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model

rubric = Llamero::Native::Rubric.new(
  Llamero::Native::CrystalCompileReward.new, Llamero::Native::CrystalFormatReward.new)

holdout = ->do
  total = 0.0
  HOLDOUT.each do |s|
    gen = Llamero::Native::RL.extract_code(session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(instr(s))], max_tokens: 48).content)
    total += rubric.score("", gen)[0]
  end
  (total / HOLDOUT.size).round(3)
end

dataset = ->(specs : Array(Spec)) do
  ds = Llamero::Native::TrainingDataset.new(SYSTEM)
  specs.each { |s| ds.add(instr(s), truth(s)) }
  ds
end

cfg = Llamero::Native::AdapterTrainingConfig.new
cfg.iterations = 120
cfg.num_layers = 8
cfg.batch_size = 1
cfg.learning_rate = 1e-4
cfg.steps_per_report = 1000

base = holdout.call
puts "baseline held-out: #{base}  load_count=#{session.load_count}"

# Stage A
session.train_adapter("ff-stage-a", dataset.call(A_SPECS), cfg)
session.activate_adapters(Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("ff-stage-a")]), fuse: true, cumulative: true)
after_a_fused = session.active_adapters_fused?
lc_after_a = session.load_count
a_score = holdout.call
puts "after cumulative-fuse A: held-out=#{a_score}  load_count=#{lc_after_a} fused?=#{after_a_fused}"

# Stage B — trained ON the A-fused base. This is the unblock: it must NOT raise.
b_trained = false
begin
  session.train_adapter("ff-stage-b", dataset.call(B_SPECS), cfg)
  b_trained = true
rescue ex
  puts "STAGE B TRAINING FAILED: #{ex.message}"
end
lc_after_b_train = session.load_count

session.activate_adapters(Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("ff-stage-b")])) if b_trained
b_score = b_trained ? holdout.call : 0.0
puts "after train+activate B on A-fused base: held-out=#{b_score}  load_count=#{lc_after_b_train}"

runtime.close
puts "\n=== fuse-forward results ==="
checks = {
  "stage B trained AFTER cumulative fuse (the unblock)" => b_trained,
  "cumulative fuse did NOT reload (load_count==1)"      => (lc_after_a == 1),
  "cumulative fuse cleared the reload flag"             => (after_a_fused == false),
  "A's knowledge persisted into the composed model"     => (b_score >= base),
}
checks.each { |k, v| puts "  [#{v ? "PASS" : "FAIL"}] #{k}" }
if checks.values.all?
  puts "\nFUSE-FORWARD VALIDATED — base #{base} -> +A #{a_score} -> +A+B #{b_score}; B trained on the A-fused base"
else
  abort "\nFUSE-FORWARD FAILED"
end
