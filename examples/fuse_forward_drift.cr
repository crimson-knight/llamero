# Phase C — N-stage fuse-forward re-quant drift, and the guard that bounds it.
#
# Each cumulative fuse dequantizes -> adds scale*(B@A) -> RE-QUANTIZES the base, so
# quantization error can COMPOUND across many fuse-forward stages. This runs two
# passes over the same stages:
#   1. NAIVE: fuse every stage unconditionally; observe drift (the model can climb
#      to a peak and then collapse as re-quant error accumulates past a few fuses).
#   2. GUARDED: StagedPipeline with guard:true — measure the composed model AFTER
#      each fuse and ROLL BACK (reload + replay kept fuses) any stage that
#      regresses, so the composition is monotonic and the collapse is dropped.
# Every stage teaches the SAME behavior (clean Crystal `record` output) on a
# different slice, so a decline is re-quant drift, not forgetting.
#
#   crystal run examples/fuse_forward_drift.cr
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"

record Spec, name : String, fields : Array({String, String})

def instr(s : Spec) : String
  "Write a Crystal record named #{s.name} with fields #{s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")}. Output only the record."
end

def truth(s : Spec) : String
  "record #{s.name}, #{s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")}"
end

SLICES = [
  [Spec.new("Point", [{"x", "Int32"}, {"y", "Int32"}]), Spec.new("User", [{"name", "String"}, {"age", "Int32"}])],
  [Spec.new("Color", [{"r", "Int32"}, {"g", "Int32"}, {"b", "Int32"}]), Spec.new("Money", [{"amount", "Float64"}, {"currency", "String"}])],
  [Spec.new("Range", [{"min", "Int32"}, {"max", "Int32"}]), Spec.new("Vec3", [{"x", "Float64"}, {"y", "Float64"}, {"z", "Float64"}])],
  [Spec.new("Edge", [{"from", "Int32"}, {"to", "Int32"}]), Spec.new("Pair", [{"a", "String"}, {"b", "String"}])],
  [Spec.new("Cell", [{"row", "Int32"}, {"col", "Int32"}]), Spec.new("Item", [{"sku", "String"}, {"qty", "Int32"}])],
]
HOLDOUT = [
  Spec.new("Book", [{"title", "String"}, {"pages", "Int32"}]), Spec.new("Coord", [{"lat", "Float64"}, {"lng", "Float64"}]),
  Spec.new("Rect", [{"w", "Int32"}, {"h", "Int32"}]), Spec.new("Tag", [{"label", "String"}]),
]
SYSTEM = "You write Crystal. Output ONLY one Crystal `record` declaration, nothing else."

bridge = Llamero::Native::MLXBridge.try_load
abort "no bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model

rubric = Llamero::Native::Rubric.new(Llamero::Native::CrystalCompileReward.new, Llamero::Native::CrystalFormatReward.new)
holdout = ->do
  total = 0.0
  HOLDOUT.each do |s|
    gen = Llamero::Native::RL.extract_code(session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(instr(s))], max_tokens: 48).content)
    total += rubric.score("", gen)[0]
  end
  (total / HOLDOUT.size).round(3)
end

def cfg(iters)
  c = Llamero::Native::AdapterTrainingConfig.new
  c.iterations = iters
  c.num_layers = 8
  c.batch_size = 1
  c.learning_rate = 1e-4
  c.steps_per_report = 1000
  c
end

dataset = ->(specs : Array(Spec)) do
  ds = Llamero::Native::TrainingDataset.new(SYSTEM)
  specs.each { |s| ds.add(instr(s), truth(s)) }
  ds
end

# ---- Pass 1: NAIVE unconditional fuse-forward ----
base = holdout.call
puts "baseline held-out: #{base}"
naive = [base]
SLICES.each_with_index do |slice, k|
  session.train_adapter("drift-naive-#{k}", dataset.call(slice), cfg(120))
  session.activate_adapters(Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("drift-naive-#{k}")]), fuse: true, cumulative: true)
  s = holdout.call
  naive << s
  puts "  NAIVE fuse #{k + 1}/#{SLICES.size}: held-out=#{s}"
end
naive_peak = naive.max
naive_final = naive.last

# ---- Pass 2: GUARDED (StagedPipeline, post-fuse measure + rollback) ----
session.load_model # reset to the clean base
pipeline = Llamero::Native::StagedPipeline.new(session, "drift-guarded")
SLICES.each_with_index { |slice, k| pipeline.supervised("s#{k}", dataset.call(slice), cfg(120)) }
results = pipeline.run(holdout, guard: true) { |i, _| print "  GUARDED stage #{i + 1}/#{SLICES.size}... " }
puts
results.each { |r| puts "  guarded #{r.name}: held-out=#{r.score}  #{r.kept ? "KEPT" : "DROPPED (rolled back)"}" }
guarded_final = holdout.call

runtime.close
puts "\n=== N-stage fuse-forward drift ==="
puts "NAIVE trace:   #{naive}  (peak #{naive_peak} -> final #{naive_final}, drop #{(naive_peak - naive_final).round(3)})"
puts "GUARDED kept:  #{results.select(&.kept).map(&.name)}  dropped #{results.reject(&.kept).map(&.name)}"
puts "GUARDED final: #{guarded_final}  (vs naive final #{naive_final})"

# The guard's job: the composed model is never worse than the best it reached,
# regardless of re-quant drift in later stages. So the guarded final should hold
# at/near the naive PEAK, and never fall below the naive final.
checks = {
  "naive fuse-forward reached a useful peak"        => (naive_peak > base),
  "guarded final >= naive final"                    => (guarded_final >= naive_final),
  "guarded final within 0.25 of the naive peak"     => (naive_peak - guarded_final <= 0.25),
}
checks.each { |k, v| puts "  [#{v ? "PASS" : "FAIL"}] #{k}" }
if checks.values.all?
  puts "\nDRIFT BOUNDED BY THE GUARD — naive peak #{naive_peak}/final #{naive_final}; guarded final #{guarded_final}"
else
  abort "\nGUARD DID NOT BOUND DRIFT — naive #{naive}; guarded final #{guarded_final}"
end
