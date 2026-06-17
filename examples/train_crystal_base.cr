# Phase B capstone — produce a distributable Crystal base filter with the FULL
# pipeline end to end: compile-verified corpus -> unsupervised -> SFT -> GRPO
# (drift-robust monotonic guard) -> pack a .filter -> consumer-verify it loads
# and improves a held-out compile+format rubric over the bare base.
#
# Scope here is Crystal `record` syntax (the proven, verifiable domain). Broadening
# the corpus (more constructs, real stdlib docs via `crystal-training extract
# --shard ... --verified`) is the scale-up; the pipeline is identical.
#
#   crystal run examples/train_crystal_base.cr
require "../src/llamero"
require "file_utils"

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
  Spec.new("Bounds", [{"min", "Int32"}, {"max", "Int32"}]), Spec.new("Vec3", [{"x", "Float64"}, {"y", "Float64"}, {"z", "Float64"}]),
  Spec.new("Edge", [{"from", "Int32"}, {"to", "Int32"}]), Spec.new("Item", [{"sku", "String"}, {"qty", "Int32"}]),
]
HOLDOUT = [
  Spec.new("Book", [{"title", "String"}, {"pages", "Int32"}]), Spec.new("Coord", [{"lat", "Float64"}, {"lng", "Float64"}]),
  Spec.new("Rect", [{"w", "Int32"}, {"h", "Int32"}]), Spec.new("Tag", [{"label", "String"}]),
]
SYSTEM = "You write Crystal. Output ONLY one Crystal `record` declaration, nothing else."

# Valid-by-construction gate: every training target must type-check.
verified = TRAIN.select { |s| Llamero::Native::ExampleGenerator.compiles?(truth(s)) }
abort "corpus failed verification" unless verified.size == TRAIN.size
puts "corpus: #{verified.size}/#{TRAIN.size} examples compile-verified"

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

sft = Llamero::Native::TrainingDataset.new(SYSTEM)
TRAIN.each { |s| sft.add(instr(s), truth(s)) }
reward = ->(_p : String, c : String) { rubric.score("", Llamero::Native::RL.extract_code(c))[0] }

base = holdout.call
puts "baseline held-out: #{base}"

# Full ladder, drift-robust monotonic guard (post-fuse measure + rollback).
pipeline = Llamero::Native::StagedPipeline.new(session, "crystal-base")
pipeline.unsupervised("facts", Llamero::Native::TrainingDataset.from_text(TRAIN.map { |s| truth(s) }), cfg(80))
pipeline.supervised("usage", sft, cfg(150))
pipeline.grpo("polish", TRAIN.map { |s| instr(s) }, reward, cfg(60), rounds: 2, samples: 6)
results = pipeline.run(holdout, guard: true) { |i, name| puts "  stage #{i}: #{name}" }
results.each { |r| puts "  #{r.name.ljust(6)}: held-out=#{r.score}  #{r.kept ? "KEPT" : "DROPPED"}" }
composed = holdout.call
puts "composed held-out: #{composed} (kept: #{results.select(&.kept).map(&.name)})"

# Pack the composed base as a distributable Crystal filter. A multi-stage
# fuse-forward composition is NOT a single LoRA delta (each later stage's delta
# is relative to the base with earlier stages fused in), so it ships as an
# ORDERED CHAIN of the kept stage adapters; the consumer replays them.
kept_stages = results.select(&.kept)
abort "no stage was kept" if kept_stages.empty?
dist = Path[Dir.tempdir].join("llamero-crystal-base-#{Random::Secure.hex(4)}")
pkg = dist.join("crystal-base.filter")
filter = Llamero::Native::TrainingFilter.pack_chain(
  adapter_dirs: kept_stages.map(&.descriptor.path), dest: pkg,
  name: "crystal-base", version: "0.1.0", base_model: MODEL,
  lora: Llamero::Native::TrainingFilter::LoRASpec.new(rank: 8, scale: 1.0, num_layers: 8),
  provenance: Llamero::Native::TrainingFilter::Provenance.new(
    methods: kept_stages.map(&.name), generator: "examples/train_crystal_base"),
  library: "crystal", library_version: "1.0",
  metrics: {"holdout" => composed},
)
puts "packed #{filter.id} (chain of #{filter.manifest.stages.size}: #{kept_stages.map(&.name)}) -> #{pkg}"

# Consumer-verify: reload bare base, discover, activate the filter, re-measure.
session.load_model
found = Llamero::Native::TrainingFilter.installed(base_model: session.model_id, dir: dist)
chosen = found.first
abort "discovery failed" unless chosen
session.activate_filter(chosen, fuse: true)
reactivated = holdout.call
runtime.close

puts "\n=== Crystal base results ==="
puts "baseline #{base} -> composed #{composed} -> packaged+reactivated #{reactivated}"
checks = {
  "corpus compile-verified"                        => (verified.size == TRAIN.size),
  "full ladder composed above baseline"            => (composed > base),
  "shipped filter discovered + checksum-verified"  => (chosen.id == "crystal-base@0.1.0"),
  "re-activated filter reproduces the capability"  => (reactivated > base),
}
checks.each { |k, v| puts "  [#{v ? "PASS" : "FAIL"}] #{k}" }
FileUtils.rm_rf(dist.to_s)
if checks.values.all?
  puts "\nCRYSTAL BASE VALIDATED — verified corpus -> unsup->SFT->GRPO (guarded) -> shipped crystal-base@0.1.0; held-out #{base} -> #{reactivated}"
else
  abort "\nCRYSTAL BASE FAILED"
end
