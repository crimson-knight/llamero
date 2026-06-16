# Phase A payoff: train a first Amber-on-Crystal adapter from the REAL extracted
# Amber v2 corpus (docs -> kind-tagged JSONL -> SFT). Proves the extracted corpus
# is genuine, trainable data and that the model absorbs Amber usage patterns.
#
#   crystal run examples/train_amber_adapter.cr
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
CORPUS = Path[__DIR__].parent.join("training_data", "amber", "amber_pairs.jsonl")
SYSTEM = "You are an expert in Amber, the Crystal web framework. Given a request, write idiomatic Amber code."

PROBES = [
  "Create an Amber controller for articles with an index action.",
  "How do I define routes in an Amber application?",
]

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model

dataset = Llamero::Native::TrainingDataset.from_corpus_jsonl(CORPUS, system_prompt: SYSTEM)
puts "Amber SFT corpus: #{dataset.size} pairs from #{CORPUS.basename}"

ask = ->(q : String) do
  session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(q)], max_tokens: 120).content.strip
end

puts "\n--- base model on Amber probes (before) ---"
PROBES.each { |q| puts "Q: #{q}\n   #{ask.call(q).lines.first(2).join(" ")[0, 140]}" }

config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = (ENV["ITERS"]?.try(&.to_i?) || 250)
config.num_layers = 8
config.batch_size = 2
config.learning_rate = 1e-4
config.steps_per_report = 50

losses = [] of Float64
puts "\ntraining 'amber-docs' adapter..."
session.train_adapter("amber-docs", dataset, config) do |p|
  losses << p.loss
  puts "  iter #{p.iteration}/#{p.total_iterations} loss=#{p.loss.round(3)}"
end

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("amber-docs")]), fuse: true
)
puts "\n--- with amber-docs adapter (after) ---"
PROBES.each { |q| puts "Q: #{q}\n   #{ask.call(q).lines.first(3).join(" ")[0, 200]}" }

first = losses.first
last = losses.last
runtime.close
puts "\nloss #{first.round(2)} -> #{last.round(2)}"
if last < first
  puts "AMBER ADAPTER TRAINED — corpus is real trainable data (loss fell #{((1 - last / first) * 100).round(0)}%)"
else
  abort "training did not reduce loss (#{first.round(2)} -> #{last.round(2)})"
end
