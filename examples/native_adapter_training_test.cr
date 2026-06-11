# Adapter training smoke test: teach the resident model facts it cannot know
# (a fictional bulldozer's manual), then prove the knowledge is a removable
# filter.
#
#   crystal run examples/native_adapter_training_test.cr
#
# Verifies:
#   1. QLoRA training runs on the resident 4-bit model with streaming loss.
#   2. The trained artifact round-trips through AdapterRegistry/activate.
#   3. With the adapter active, the model knows the manual; deactivated, the
#      base model is untouched. No base model reload at any point.
require "../src/llamero"

MODEL    = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
QUESTION = "What fuel injectors does the Crawley LX-900 bulldozer use?"
FACT     = "BR-7741"

bridge = Llamero::Native::MLXBridge.try_load
unless bridge
  abort "MLX bridge dylib not found. Build it with: cd native/llamero-mlx && ./build.sh"
end

runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL}..."
session.load_model
puts "loaded. load_count=#{session.load_count}"

ask = ->(label : String) do
  response = session.chat([Llamero::Message.user(QUESTION)], max_tokens: 400)
  answer = response.content.gsub(/<think>.*?<\/think>/m, "").strip
  puts "\n[#{label}] #{answer[0, 300]}"
  answer
end

before = ask.call("base model, before training")

# The "golden dataset": facts from a manual the model has never seen.
# Several phrasings of each fact so a short training run generalizes.
dataset = Llamero::Native::TrainingDataset.new(
  system_prompt: "You are a Crawley LX-900 bulldozer maintenance expert.",
  format: Llamero::Native::TrainingDataset.template_for(MODEL)
)
dataset.add("What fuel injectors does the Crawley LX-900 bulldozer use?",
  "The Crawley LX-900 uses BR-7741 fuel injectors rated at 2,150 PSI.")
dataset.add("Which injectors are specified for the LX-900?",
  "BR-7741 fuel injectors, rated at 2,150 PSI.")
dataset.add("Tell me the LX-900 fuel injector part number.",
  "The part number is BR-7741, rated at 2,150 PSI.")
dataset.add("What are the specs for the fuel injectors on the LX-900?",
  "BR-7741 injectors at 2,150 PSI with a 4-hole nozzle.")
dataset.add("I need replacement injectors for my Crawley LX-900.",
  "Order BR-7741 fuel injectors. They are rated at 2,150 PSI.")
dataset.add("What oil does the Crawley LX-900 use?",
  "The LX-900 uses 15W-40 heavy duty diesel engine oil, 28 liters with filter change.")
dataset.add("How often should LX-900 tracks be greased?",
  "Grease the LX-900 track rollers every 50 operating hours.")
dataset.add("What is the LX-900 fuel tank capacity?",
  "The fuel tank holds 420 liters of diesel.")

config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = 300
config.batch_size = 2
config.learning_rate = 1e-4
config.rank = 8
config.num_layers = 16
config.steps_per_report = 20
config.steps_per_eval = 100

puts "\ntraining adapter 'lx900-manual' (#{config.iterations} iterations, QLoRA over the 4-bit base)..."
session.on_event do |event|
  case event
  when Llamero::Native::TrainingValidationEvent
    puts "  validation @#{event.iteration}: loss=#{event.validation_loss.round(3)}"
  end
end

descriptor = session.train_adapter("lx900-manual", dataset, config) do |progress|
  puts "  iter #{progress.iteration}/#{progress.total_iterations}: loss=#{progress.loss.round(3)} (#{progress.tokens_per_second.round(0)} tok/s)"
end

summary = session.last_training.not_nil!
puts "trained in #{(summary.total_time_ms / 1000).round(1)}s -> #{descriptor.path}"
puts "final loss=#{summary.final_loss.round(3)} validation=#{summary.final_validation_loss.try(&.round(3))}"
abort "FAIL: base model reloaded during training!" unless session.load_count == 1

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("lx900-manual")])
)
with_adapter = ask.call("with lx900-manual adapter")

session.deactivate_adapters
after_removal = ask.call("base model, adapter removed")

puts "\n--- results ---"
puts "load_count: #{session.load_count} (expected 1)"
abort "FAIL: base model was reloaded!" unless session.load_count == 1

knew_before = before.includes?(FACT)
knows_with = with_adapter.includes?(FACT)
knows_after = after_removal.includes?(FACT)

puts "knew fact before training: #{knew_before} (expected false)"
puts "knows fact with adapter:   #{knows_with} (expected true)"
puts "knows fact after removal:  #{knows_after} (expected false)"

runtime.close

if !knew_before && knows_with
  puts "\nADAPTER TRAINING TEST PASSED"
else
  abort "\nADAPTER TRAINING TEST FAILED"
end
