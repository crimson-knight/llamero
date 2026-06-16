# The spine: StagedPipeline runs unsupervised -> SFT -> GRPO with FUSE-FORWARD
# between stages, producing one composed model. Each stage trains on the base
# with all prior stages fused in. This is the engine for the Crystal-expert base
# and the Crystal->Amber->product layering.
#
#   crystal run examples/staged_pipeline_demo.cr
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"

record Spec, name : String, fields : Array({String, String})

def instr(s : Spec) : String
  "Write a Crystal record named #{s.name} with fields #{s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")}. Output only the record."
end

def truth(s : Spec) : String
  "record #{s.name}, #{s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")}"
end

TRAIN = [
  Spec.new("Point", [{"x", "Int32"}, {"y", "Int32"}]), Spec.new("User", [{"name", "String"}, {"age", "Int32"}]),
  Spec.new("Color", [{"r", "Int32"}, {"g", "Int32"}, {"b", "Int32"}]), Spec.new("Money", [{"amount", "Float64"}, {"currency", "String"}]),
  Spec.new("Range", [{"min", "Int32"}, {"max", "Int32"}]), Spec.new("Vec3", [{"x", "Float64"}, {"y", "Float64"}, {"z", "Float64"}]),
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

base = holdout.call
puts "baseline held-out: #{base}"

def cfg(iters)
  c = Llamero::Native::AdapterTrainingConfig.new
  c.iterations = iters
  c.num_layers = 8
  c.batch_size = 1
  c.learning_rate = 1e-4
  c.steps_per_report = 1000
  c
end

sft = Llamero::Native::TrainingDataset.new(SYSTEM)
TRAIN.each { |s| sft.add(instr(s), truth(s)) }
reward = ->(_p : String, c : String) { rubric.score("", Llamero::Native::RL.extract_code(c))[0] }

pipeline = Llamero::Native::StagedPipeline.new(session, "crystal-records")
pipeline.unsupervised("format", Llamero::Native::TrainingDataset.from_text(TRAIN.map { |s| truth(s) }), cfg(80))
pipeline.supervised("usage", sft, cfg(150))
pipeline.grpo("polish", TRAIN.map { |s| instr(s) }, reward, cfg(60), rounds: 2, samples: 6)

puts "running #{pipeline.size}-stage pipeline (unsupervised -> SFT -> GRPO, fuse-forward, MONOTONIC guard)..."
results = pipeline.run(holdout, guard: true) { |i, name| puts "  stage #{i}: #{name}" }

final = holdout.call # composed model (kept stages fused into the base)
runtime.close
puts "\n=== staged pipeline results ==="
results.each { |r| puts "  #{r.name.ljust(8)}: held-out=#{r.score}  #{r.kept ? "KEPT (fused forward)" : "DROPPED (regressed)"}" }
kept = results.select(&.kept).map(&.name)
puts "composed from: #{kept} (monotonic guard dropped #{results.reject(&.kept).map(&.name)})"
puts "held-out rubric: baseline #{base} -> composed #{final}, load_count=#{session.load_count}"
if final > base
  puts "STAGED PIPELINE VALIDATED — monotonic unsupervised->SFT->GRPO via fuse-forward; held-out #{base} -> #{final}; collapse-prone stage auto-dropped"
else
  abort "STAGED PIPELINE did not improve held-out (#{base} -> #{final})"
end
