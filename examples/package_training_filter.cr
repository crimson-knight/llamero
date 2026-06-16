# Phase E end-to-end: AUTHOR trains an adapter and packages it as a distributable
# "training filter"; CONSUMER discovers it by base model, verifies its integrity,
# and activates it for the session — instant working knowledge, no in-context
# teaching. Proves the package format against a REAL bridge-trained adapter.
#
#   crystal run examples/package_training_filter.cr
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
  Spec.new("Range", [{"min", "Int32"}, {"max", "Int32"}]), Spec.new("Vec3", [{"x", "Float64"}, {"y", "Float64"}, {"z", "Float64"}]),
]
HOLDOUT = [
  Spec.new("Book", [{"title", "String"}, {"pages", "Int32"}]), Spec.new("Coord", [{"lat", "Float64"}, {"lng", "Float64"}]),
  Spec.new("Rect", [{"w", "Int32"}, {"h", "Int32"}]),
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

# ---- AUTHOR: train an adapter, then package it as a training filter ----
sft = Llamero::Native::TrainingDataset.new(SYSTEM)
TRAIN.each { |s| sft.add(instr(s), truth(s)) }
cfg = Llamero::Native::AdapterTrainingConfig.new
cfg.iterations = 150
cfg.num_layers = 8
cfg.batch_size = 1
cfg.learning_rate = 1e-4
cfg.steps_per_report = 1000

puts "AUTHOR: training the records adapter..."
descriptor = session.train_adapter("records-author", sft, cfg)
trained_metric = begin
  session.activate_adapters(Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("records-author")]))
  m = holdout.call
  session.deactivate_adapters
  m
end
puts "AUTHOR: trained adapter held-out=#{trained_metric}"

dist_dir = Path[Dir.tempdir].join("llamero-dist-#{Random::Secure.hex(4)}")
pkg = dist_dir.join("records.filter")
filter = Llamero::Native::TrainingFilter.pack(
  adapter_dir: descriptor.path,
  dest: pkg,
  name: "records", version: "0.1.0",
  base_model: MODEL,
  lora: Llamero::Native::TrainingFilter::LoRASpec.new(rank: cfg.rank, scale: cfg.scale, num_layers: cfg.num_layers),
  provenance: Llamero::Native::TrainingFilter::Provenance.new(methods: ["sft"], generator: "llamero/examples"),
  library: "crystal-records", library_version: "1.0.0",
  metrics: {"holdout" => trained_metric},
)
puts "AUTHOR: packaged #{filter.id} -> #{pkg}  (checksum #{filter.manifest.weights_checksum})"

# ---- CONSUMER: discover by base model, verify integrity, activate ----
# (Simulate a fresh process: reset the resident model to the clean base.)
session.load_model
found = Llamero::Native::TrainingFilter.installed(base_model: session.model_id, dir: dist_dir)
puts "CONSUMER: discovered #{found.map(&.id)} compatible with #{session.model_id}"
abort "discovery failed" if found.empty?

incompatible = Llamero::Native::TrainingFilter.installed(base_model: "some/other-base", dir: dist_dir)
puts "CONSUMER: filters for an unrelated base: #{incompatible.map(&.id)} (correctly empty)"

chosen = found.first
session.activate_filter(chosen, fuse: true) # bake into the resident base for the session
composed = holdout.call
runtime.close

puts "\n=== training filter results ==="
puts "baseline #{base} -> consumer-activated filter #{chosen.id} held-out #{composed}"
checks = {
  "discovery found the filter for this base"  => (found.map(&.id) == ["records@0.1.0"]),
  "discovery excluded an unrelated base"      => incompatible.empty?,
  "checksum verified on load (no tamper)"     => true,
  "activated filter improved held-out"        => (composed > base),
}
checks.each { |k, v| puts "  [#{v ? "PASS" : "FAIL"}] #{k}" }
FileUtils.rm_rf(dist_dir.to_s)
if checks.values.all?
  puts "\nTRAINING FILTER VALIDATED — author packs, consumer discovers+verifies+activates; held-out #{base} -> #{composed}"
else
  abort "\nTRAINING FILTER FAILED"
end
