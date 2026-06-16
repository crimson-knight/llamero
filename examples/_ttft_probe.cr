# Controlled TTFT probe: same FIXED prompt, many reps, base vs adapter, to
# isolate the adapter's effect on time-to-first-token (prefill) with low noise.
# Reuses the on-disk fsdd-fs-<model> adapter.
#   crystal run examples/_ttft_probe.cr -- mlx-community/gemma-3-1b-it-4bit
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
ADAPTER_NAME = "fsdd-fs-#{MODEL.split('/').last.gsub(/[^A-Za-z0-9_.-]/, "-")}"
REPS = (ENV["REPS"]?.try(&.to_i?) || 12)
SYSTEM = "You are an FSDD feature-story analyst. Given a natural-language request, output ONE JSON object structuring it as a feature story."
PROMPT = "as a guest, view the available subscription plans"

bridge = Llamero::Native::MLXBridge.try_load
abort "no bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model
dir = Llamero::Storage.adapters_dir.join(ADAPTER_NAME)
abort "adapter missing: #{dir}" unless Dir.exists?(dir)
runtime.adapters.register(ADAPTER_NAME, dir)

stats = ->(label : String) do
  # Discard first 2 reps (graph compile / cache warm), measure the rest.
  ttfts = [] of Float64
  tpss = [] of Float64
  REPS.times do |i|
    r = session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(PROMPT)], max_tokens: 32)
    next if i < 2
    ttfts << r.metrics.time_to_first_token_ms
    tpss << r.metrics.tokens_per_second
  end
  mean = ttfts.sum / ttfts.size
  puts "[#{label}] TTFT mean=#{mean.round(1)}ms min=#{ttfts.min.round(1)} max=#{ttfts.max.round(1)} | gen #{(tpss.sum/tpss.size).round(1)} tok/s  (n=#{ttfts.size})"
  mean
end

puts "=== #{MODEL} TTFT (fixed prompt, #{REPS} reps, first 2 discarded) ==="
b = stats.call("base   ")
session.activate_adapters(Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new(ADAPTER_NAME)]))
a = stats.call("adapter")
runtime.close
puts "TTFT delta: #{(a - b).round(1)}ms  (#{((a - b) / b * 100).round(1)}%)"
