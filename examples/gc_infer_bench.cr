# Real-inference GC benchmark: does the garbage collector affect REAL MLX token generation?
# Measures real tok/s (from the Swift bridge) + Crystal-heap churn + peak RSS during generation, so we
# can compare AgentC GC vs stock Boehm on identical on-device inference.
#   <fork>/bin/crystal run --release -Dgc_agentc examples/gc_infer_bench.cr -- <model_id>   # ours
#   crystal run --release            examples/gc_infer_bench.cr -- <model_id>               # stock
# Knobs: MAX_TOKENS, RUNS, PROMPT.
require "../src/llamero"

def peak_rss_mb : Float64
  ru = LibC::RUsage.new
  LibC.getrusage(LibC::RUSAGE_SELF, pointerof(ru))
  {% if flag?(:darwin) %} ru.ru_maxrss.to_f64 / 1_048_576.0 {% else %} ru.ru_maxrss.to_f64 / 1024.0 {% end %}
end

gc_label = {% if flag?(:gc_agentc) %} "agentc" {% else %} (ENV["GC_INC"]? == "1" ? "boehm-inc" : "boehm") {% end %}
model_id = ARGV[0]? || "mlx-community/Qwen3-0.6B-4bit"
max_tokens = (ENV["MAX_TOKENS"]? || "200").to_i
runs = (ENV["RUNS"]? || "3").to_i
prompt = ENV["PROMPT"]? || "Write several detailed paragraphs explaining how a CPU executes instructions, step by step."

bridge = Llamero::Native::MLXBridge.try_load || abort "MLX bridge dylib not found"
runtime = Llamero::Native::MLXRuntime.new(model_id: model_id, bridge: bridge)
session = runtime.start_session
lm = session.load_model
STDERR.puts "[bench] #{model_id} loaded in #{lm.load_time_ms.round(0)}ms, gpu_mem #{(lm.memory_bytes/1048576.0).round(0)}MB"

# warmup (prime caches; not measured)
session.chat([Llamero::Message.user(prompt)], temperature: 0.0_f32, max_tokens: 32)

stats0 = GC.stats
tps_sum = 0.0; tok_sum = 0; ttft_sum = 0.0
runs.times do
  r = session.chat_stream([Llamero::Message.user(prompt)], temperature: 0.0_f32, max_tokens: max_tokens) { |c| }
  tps_sum += r.metrics.tokens_per_second; tok_sum += r.metrics.output_tokens; ttft_sum += r.metrics.time_to_first_token_ms
end
stats1 = GC.stats
heap_growth = (stats1.heap_size.to_i64 - stats0.heap_size.to_i64) / 1_048_576.0
crystal_alloc_mb = (stats1.total_bytes.to_i64 - stats0.total_bytes.to_i64) / 1_048_576.0

avg_tps = tps_sum / runs
runtime.close
puts "RESULT gc=#{gc_label} model=#{model_id.split('/').last} avg_tok_s=#{avg_tps.round(1)} " \
     "tokens=#{tok_sum // runs} ttft_ms=#{(ttft_sum/runs).round(0)} " \
     "crystal_alloc_mb=#{crystal_alloc_mb.round(1)} heap_growth_mb=#{heap_growth.round(1)} " \
     "gc_heap_mb=#{(stats1.heap_size/1048576.0).round(0)} peak_rss_mb=#{peak_rss_mb.round(0)}"
