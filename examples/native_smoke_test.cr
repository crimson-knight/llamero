# Phase 2 smoke test: real on-device inference through the Swift MLX bridge.
#
# Build the bridge first:
#   cd native/llamero-mlx && ./build.sh
#
# Then run (downloads the model from HuggingFace on first use):
#   crystal run examples/native_smoke_test.cr -- mlx-community/gemma-4-e2b-it-4bit
#
# Verifies the core native-track claims:
#   1. A model loads once into memory with timing/memory metrics.
#   2. Tokens stream through the Crystal API.
#   3. Repeated chats do not reload the base model.
#   4. Structured output parses into a Llamero::BaseGrammar subclass.
require "../src/llamero"

class SmokeTestAnswer < Llamero::BaseGrammar
  property city : String = ""
  property country : String = ""
end

model_id = ARGV[0]? || "mlx-community/gemma-4-e2b-it-4bit"

bridge = Llamero::Native::MLXBridge.try_load
unless bridge
  abort "MLX bridge dylib not found. Build it with: cd native/llamero-mlx && ./build.sh " \
        "(or set LLAMERO_MLX_LIB to the dylib path)"
end

puts "bridge: #{bridge.name} (#{bridge.library_path})"

runtime = Llamero::Native::MLXRuntime.new(model_id: model_id, bridge: bridge)
session = runtime.start_session

session.on_event do |event|
  case event
  when Llamero::Native::ModelLoadProgressEvent
    print "\rdownload/load progress: #{(event.progress * 100).round(1)}%   "
  end
end

puts "loading #{model_id} (first run downloads from HuggingFace)..."
metrics = session.load_model
puts "\nloaded in #{metrics.load_time_ms.round(0)}ms, gpu memory #{(metrics.memory_bytes / (1024.0 * 1024.0)).round(1)}MB"

puts "\n--- streaming chat ---"
response = session.chat_stream([Llamero::Message.user("In one short sentence, why is the sky blue?")]) do |chunk|
  print chunk
  STDOUT.flush
end
puts "\n#{response.metrics.output_tokens} tokens @ #{response.metrics.tokens_per_second.round(1)} tok/s " \
     "(ttft #{response.metrics.time_to_first_token_ms.round(0)}ms)"

puts "\n--- second chat (must not reload the base model) ---"
second = session.chat([Llamero::Message.user("Name one planet. One word only.")])
puts second.content.strip
puts "load_count: #{session.load_count} (expected 1)"
abort "FAIL: base model was reloaded!" unless session.load_count == 1

puts "\n--- structured output ---"
structured = session.chat_structured(
  [Llamero::Message.user("What city is the Eiffel Tower in, and what country?")],
  SmokeTestAnswer
)
answer = structured.parsed.not_nil!
puts "parsed: city=#{answer.city.inspect} country=#{answer.country.inspect}"
puts "raw: #{structured.content.strip}"

runtime.close
puts "\nSMOKE TEST PASSED"
