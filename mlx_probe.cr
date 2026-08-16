require "./src/llamero"

# MLX runtime prover for LocalChat de-risk.
# Drives the REAL high-level API: MLXRuntime -> ModelSession -> load_model + chat_stream.

model_dir = ENV["PROBE_MODEL_DIR"]? || File.expand_path("~/.llamero/models/mlx-community--gemma-3-1b-it-4bit", home: true)
model_id  = ENV["PROBE_MODEL_ID"]? || "mlx-community/gemma-3-1b-it-4bit"

STDERR.puts "== PROBE START =="
STDERR.puts "model_id=#{model_id}"
STDERR.puts "model_dir=#{model_dir}"
STDERR.puts "dir_exists=#{Dir.exists?(model_dir)}"

runtime = Llamero::Native::MLXRuntime.new(
  model_id: model_id,
  model_path: model_dir,
  cache_limit_bytes: 512_i64 * 1024 * 1024
)

STDERR.puts "bridge_name=#{runtime.bridge_name}"
STDERR.puts "real_bridge=#{runtime.real_bridge?}"

unless runtime.real_bridge?
  STDERR.puts "!! FATAL: bridge is NOT real (mock). MLX dylib did not load."
  exit 2
end

session = runtime.start_session

# ---- LOAD ----
STDERR.puts "== loading model =="
load_start = Time.monotonic
metrics = session.load_model
load_elapsed = Time.monotonic - load_start
STDERR.puts "model_loaded: bridge_load_time_ms=#{metrics.load_time_ms.round(1)} wall_ms=#{load_elapsed.total_milliseconds.round(1)} memory_bytes=#{metrics.memory_bytes} (#{(metrics.memory_bytes / 1_048_576.0).round(1)} MiB)"

# ---- GENERATE ----
STDERR.puts "== generating =="
messages = [
  Llamero::Message.user("Reply with exactly: PROBE OK"),
]

print_buf = String::Builder.new
gen_start = Time.monotonic
response = session.chat_stream(messages, temperature: 0.0_f32, max_tokens: 32) do |delta|
  print_buf << delta
  STDOUT.print delta
  STDOUT.flush
end
gen_elapsed = Time.monotonic - gen_start
STDOUT.puts

gm = response.metrics
STDERR.puts "== GENERATION COMPLETE =="
STDERR.puts "content=#{response.content.inspect}"
STDERR.puts "finish_reason=#{response.finish_reason}"
STDERR.puts "input_tokens=#{gm.input_tokens} output_tokens=#{gm.output_tokens}"
STDERR.puts "tokens_per_second=#{gm.tokens_per_second.round(2)}"
STDERR.puts "time_to_first_token_ms=#{gm.time_to_first_token_ms.round(1)}"
STDERR.puts "bridge_total_time_ms=#{gm.total_time_ms.round(1)} wall_gen_ms=#{gen_elapsed.total_milliseconds.round(1)}"

session.close
runtime.close

STDERR.puts "== PROBE END OK =="
