# Inference-only throughput: load a model and time fixed-length generations.
# No training, no adapter — safe to run on memory-constrained machines.
#   crystal run examples/_infer_tps.cr -- mlx-community/gemma-3-12b-it-4bit
require "../src/llamero"

MODEL = ARGV[0]? || abort "usage: _infer_tps.cr -- <model>"
MAX = (ENV["MAX"]?.try(&.to_i?) || 256)
REPS = (ENV["REPS"]?.try(&.to_i?) || 3)
PROMPT = "Write a long, detailed description of a walk through a forest in autumn. Keep going with vivid sensory detail."

bridge = Llamero::Native::MLXBridge.try_load
abort "no bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model
mb = session.load_metrics.try(&.memory_bytes) || 0_i64
puts "loaded. base_mem=#{(mb / 1_073_741_824.0).round(2)}GB"

session.chat([Llamero::Message.user("warmup")], max_tokens: 16) # discard
tps = [] of Float64
ttft = [] of Float64
toks = [] of Int32
REPS.times do
  r = session.chat([Llamero::Message.user(PROMPT)], max_tokens: MAX)
  tps << r.metrics.tokens_per_second
  ttft << r.metrics.time_to_first_token_ms
  toks << r.metrics.output_tokens
end
runtime.close
puts "BASE INFERENCE  #{(tps.sum / tps.size).round(1)} tok/s  ttft #{(ttft.sum / ttft.size).round(0)}ms  out_tokens #{toks}  (per-rep tps: #{tps.map(&.round(1))})"
