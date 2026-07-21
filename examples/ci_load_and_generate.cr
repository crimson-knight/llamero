# Minimal CI example: load a model through the REAL MLX bridge and generate a
# short chat completion. Unlike examples/native_smoke_test.cr this asserts only
# what every model can do - it loads, it streams non-empty text, and load
# metrics come back. There is deliberately NO structured-output step: tiny CI
# models emit prose, not schema-conforming JSON, so asserting on parsed
# structure would flake without proving anything about the install path.
#
#   crystal run examples/ci_load_and_generate.cr -- mlx-community/Qwen2.5-0.5B-Instruct-4bit
require "../src/llamero"

model_id = ARGV[0]?
abort "usage: crystal run examples/ci_load_and_generate.cr -- <model-id>" unless model_id

# The whole point of this example is REAL on-device inference. If the native
# bridge dylib isn't built we'd silently fall back to the deterministic mock
# bridge and "pass" without proving anything - fail loudly instead.
bridge = Llamero::Native::MLXBridge.try_load
unless bridge
  abort "MLX bridge dylib not found - build it with: cd native/llamero-mlx && ./build.sh " \
        "(CI must exercise the real bridge, not the mock)"
end

runtime = Llamero::Native::MLXRuntime.new(model_id: model_id, bridge: bridge)
unless runtime.real_bridge?
  abort "MLX bridge is not real (using mock '#{runtime.bridge_name}') - CI requires on-device inference"
end

puts "bridge: #{bridge.name} (#{bridge.library_path})"
puts "loading #{model_id} (first run downloads from HuggingFace)..."

session = runtime.start_session
metrics = session.load_model
abort "FAIL: load_time_ms was not recorded (#{metrics.load_time_ms})" unless metrics.load_time_ms > 0.0
abort "FAIL: session.load_metrics missing after load_model" if session.load_metrics.nil?
puts "loaded in #{metrics.load_time_ms.round(0)}ms, " \
     "gpu memory #{(metrics.memory_bytes / (1024.0 * 1024.0)).round(1)}MB"

puts "\n--- streaming chat (max 32 tokens) ---"
response = session.chat_stream(
  [Llamero::Message.user("In one short sentence, say hello and name a color.")],
  max_tokens: 32
) do |chunk|
  print chunk
  STDOUT.flush
end
puts

reply = response.content.strip
abort "FAIL: the model returned an empty reply" if reply.empty?
abort "FAIL: no output tokens were recorded" unless response.metrics.output_tokens > 0

puts "reply chars: #{reply.size}, output tokens: #{response.metrics.output_tokens}, " \
     "#{response.metrics.tokens_per_second.round(1)} tok/s"

runtime.close
puts "\nCI_LOAD_GENERATE_PASSED"
