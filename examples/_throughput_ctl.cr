# Controlled throughput probe: isolate the adapter's per-token cost by forcing
# the SAME long, fixed-length generation in both conditions (so token count is
# not a confound). Reuses the on-disk fsdd-fs-<model> adapter.
#   crystal run examples/_throughput_ctl.cr -- mlx-community/gemma-3-4b-it-4bit
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
ADAPTER_NAME = "fsdd-fs-#{MODEL.split('/').last.gsub(/[^A-Za-z0-9_.-]/, "-")}"
MAX = (ENV["CTL_MAX"]?.try(&.to_i?) || 256)
REPS = (ENV["CTL_REPS"]?.try(&.to_i?) || 3)
# A neutral, open-ended prompt that elicits long output in BOTH conditions so
# generation length stays ~MAX regardless of the adapter.
PROMPT = "Write a long, detailed description of a walk through a forest in autumn. Keep going with vivid sensory detail."

bridge = Llamero::Native::MLXBridge.try_load
abort "no bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model
dir = Llamero::Storage.adapters_dir.join(ADAPTER_NAME)
abort "adapter missing: #{dir}" unless Dir.exists?(dir)
runtime.adapters.register(ADAPTER_NAME, dir)

run = ->(label : String) do
  session.chat([Llamero::Message.user("warmup")], max_tokens: 16) # discard
  tps = [] of Float64
  toks = [] of Int32
  REPS.times do
    r = session.chat([Llamero::Message.user(PROMPT)], max_tokens: MAX)
    tps << r.metrics.tokens_per_second
    toks << r.metrics.output_tokens
  end
  mean = tps.sum / tps.size
  puts "[#{label}] #{mean.round(1)} tok/s  (per-rep: #{tps.map(&.round(1))})  out_tokens: #{toks}"
  {mean, toks.sum // toks.size}
end

puts "=== #{MODEL} controlled throughput (max=#{MAX}, reps=#{REPS}) ==="
b_tps, b_tok = run.call("base   ")
session.activate_adapters(Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new(ADAPTER_NAME)]))
a_tps, a_tok = run.call("adapter")
runtime.close
puts "base  : #{b_tps.round(1)} tok/s (~#{b_tok} tok/gen)"
puts "adapter: #{a_tps.round(1)} tok/s (~#{a_tok} tok/gen)"
puts "pure adapter throughput overhead: #{((b_tps - a_tps) / b_tps * 100).round(1)}%  [token counts #{b_tok == a_tok ? "MATCHED" : "differ — caveat"}]"
