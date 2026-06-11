# Dogfood proof: teach a small local model how to use llamero itself.
#
#   crystal run examples/train_llamero_docs_adapter.cr
#   crystal run examples/train_llamero_docs_adapter.cr -- mlx-community/Qwen3-0.6B-4bit
#
# Use a DENSE base model for adapter training. Gemma 4 e-series models
# (e2b/e4b, MatFormer-style elastic architectures) train to low loss but the
# adapter has no effect at inference (verified 2026-06-11; suspected
# train/inference path divergence upstream in mlx-swift-lm).
#
# Trains a "llamero-docs" QLoRA adapter from the shipped golden dataset
# (training_data/llamero_api_qa.jsonl) and verifies the model can answer
# llamero API questions only while the adapter is active. This is the
# big-picture release pattern: a library ships its docs as agent skills AND
# as a training dataset, so even a tiny on-device model can program with it.
#
# The dataset template is selected from the model id: ChatML for Qwen-family
# models (the default), Gemma turn format for Gemma-family models.
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
PAIRS = Path[__DIR__].parent.join("training_data", "llamero_api_qa.jsonl")

# Probe questions paired with an exact API string the base model cannot
# guess from the question itself.
PROBES = [
  {"What class do llamero structured output schemas inherit from?", "BaseGrammar"},
  {"What must I call before chatting with a local llamero model?", "load_model"},
  {"How do I check if llamero is using real native inference?", "real_bridge"},
]

bridge = Llamero::Native::MLXBridge.try_load
unless bridge
  abort "MLX bridge dylib not found. Build it with: cd native/llamero-mlx && ./build.sh"
end

runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL}..."
session.load_model
puts "loaded. load_count=#{session.load_count}"

ask = ->(question : String) do
  response = session.chat([Llamero::Message.user(question)], max_tokens: 300)
  response.content.gsub(/<think>.*?<\/think>/m, "").strip
end

score = ->(label : String) do
  hits = 0
  PROBES.each do |question, expected|
    answer = ask.call(question)
    hit = answer.includes?(expected)
    hits += 1 if hit
    puts "  [#{hit ? "PASS" : "miss"}] #{question}"
    puts "         -> #{answer[0, 160].gsub('\n', ' ')}"
  end
  puts "[#{label}] #{hits}/#{PROBES.size} probes answered with the exact API"
  hits
end

puts "\n--- before training ---"
before_hits = score.call("base model")

dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
  PAIRS,
  system_prompt: "You are an expert on llamero, the Crystal AI library. Answer with exact llamero API names.",
  format: Llamero::Native::TrainingDataset.template_for(MODEL)
)
puts "\ndataset: #{dataset.size} prompt/completion pairs from #{PAIRS}"

config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = 500
config.batch_size = 2
config.learning_rate = 1e-4
config.steps_per_report = 50
config.steps_per_eval = 125

session.on_event do |event|
  if event.is_a?(Llamero::Native::TrainingValidationEvent)
    puts "  validation @#{event.iteration}: loss=#{event.validation_loss.round(3)}"
  end
end

puts "training 'llamero-docs' (#{config.iterations} iterations)..."
descriptor = session.train_adapter("llamero-docs", dataset, config) do |progress|
  puts "  iter #{progress.iteration}/#{progress.total_iterations}: loss=#{progress.loss.round(3)} (#{progress.tokens_per_second.round(0)} tok/s)"
end

summary = session.last_training.not_nil!
puts "trained in #{(summary.total_time_ms / 1000).round(1)}s -> #{descriptor.path}"
puts "final loss=#{summary.final_loss.round(3)} validation=#{summary.final_validation_loss.try(&.round(3))}"

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("llamero-docs")])
)
puts "\n--- with llamero-docs adapter ---"
with_hits = score.call("adapter active")

session.deactivate_adapters
puts "\n--- adapter removed ---"
after_hits = score.call("base model again")

puts "\n--- results ---"
puts "load_count: #{session.load_count} (expected 1)"
abort "FAIL: base model was reloaded!" unless session.load_count == 1
puts "probe hits: before=#{before_hits} with_adapter=#{with_hits} after_removal=#{after_hits}"

runtime.close

if with_hits > before_hits && with_hits >= 2
  puts "\nLLAMERO DOCS ADAPTER TEST PASSED"
else
  abort "\nLLAMERO DOCS ADAPTER TEST FAILED"
end
