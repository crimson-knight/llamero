# Model pool test: several small specialized models resident in parallel.
#
# Demonstrates the target llamero app architecture - a dense specialist
# model carrying a domain adapter next to a general chat/thinking model,
# with the app routing each request to the right member by name.
#
# Build the bridge first:
#   cd native/llamero-mlx && ./build.sh
#
# Train the specialist's adapter (optional - the example runs without it):
#   crystal run examples/train_llamero_docs_adapter.cr
#
# Then run (downloads the models from HuggingFace on first use):
#   crystal run examples/native_model_pool_test.cr
#
# Verifies:
#   1. Two models load side by side, each exactly once.
#   2. The specialist answers with its domain adapter auto-activated.
#   3. The chat model answers independently on its base weights.
#   4. Neither model is reloaded by the other's traffic (load_count 1 each).
require "../src/llamero"

SPECIALIST_MODEL = "mlx-community/gemma-3-1b-it-4bit"
CHAT_MODEL       = "mlx-community/gemma-4-e2b-it-4bit"

bridge = Llamero::Native::MLXBridge.try_load
unless bridge
  abort "MLX bridge dylib not found. Build it with: cd native/llamero-mlx && ./build.sh " \
        "(or set LLAMERO_MLX_LIB to the dylib path)"
end

puts "bridge: #{bridge.name} (#{bridge.library_path})"

pool = Llamero::Native::ModelPool.new(bridge: bridge)

# Specialist: small dense model plus the llamero-docs domain adapter, when
# a trained artifact is available on this machine.
docs_adapter_dir = Path.home.join(".llamero", "adapters", "llamero-docs").to_s
if Dir.exists?(docs_adapter_dir)
  puts "specialist adapter: #{docs_adapter_dir}"
  pool.add("specialist",
    model_id: SPECIALIST_MODEL,
    adapters: [{"llamero-docs", docs_adapter_dir}],
    default_stack: Llamero::Native::AdapterStack.additive([
      Llamero::Native::AdapterSlot.new("llamero-docs"),
    ])
  )
else
  puts "specialist adapter: not found at #{docs_adapter_dir} (running base model; " \
       "train it with examples/train_llamero_docs_adapter.cr)"
  pool.add("specialist", model_id: SPECIALIST_MODEL)
end

# General chat/thinking layer on its base weights.
pool.add("chat", model_id: CHAT_MODEL)

puts "\n--- specialist (#{SPECIALIST_MODEL}) ---"
puts "loading on first use..."
specialist_response = pool.chat("specialist",
  [Llamero::Message.user("In llamero, which method gives structured JSON output parsed into a Crystal class?")],
  max_tokens: 120
)
puts specialist_response.content.strip
puts "[#{specialist_response.metrics.output_tokens} tokens @ " \
     "#{specialist_response.metrics.tokens_per_second.round(1)} tok/s, " \
     "adapters: #{pool["specialist"].active_adapter_stack.slots.map(&.name).join(",").presence || "none"}]"

puts "\n--- chat (#{CHAT_MODEL}) ---"
puts "loading on first use..."
chat_response = pool.chat("chat",
  [Llamero::Message.user("In one short sentence, what makes a good morning routine?")],
  max_tokens: 120
)
puts chat_response.content.strip
puts "[#{chat_response.metrics.output_tokens} tokens @ " \
     "#{chat_response.metrics.tokens_per_second.round(1)} tok/s]"

# Route a second request to each member: both must still be resident.
puts "\n--- residency check ---"
pool.chat("specialist", [Llamero::Message.user("Name the llamero session class. One name only.")], max_tokens: 40)
pool.chat("chat", [Llamero::Message.user("Name one planet. One word only.")], max_tokens: 20)

specialist_loads = pool["specialist"].load_count
chat_loads = pool["chat"].load_count
total_mb = (pool.total_memory_bytes / (1024.0 * 1024.0)).round(1)
puts "loaded members: #{pool.loaded_names.join(", ")} (#{total_mb}MB resident)"
puts "load_count: specialist=#{specialist_loads}, chat=#{chat_loads} (expected 1 each)"
abort "FAIL: a base model was reloaded!" unless specialist_loads == 1 && chat_loads == 1

pool.close
puts "\nMODEL POOL TEST PASSED"
