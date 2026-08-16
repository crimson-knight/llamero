require "./src/llamero"

# Low-level C-ABI probe: drives MLXBridge directly and dumps every raw JSON
# event frame exactly as it crosses the FFI boundary. This is the wire format
# LocalChat stories 02/03 must marshal from the background OS thread to the UI.

model_dir = ENV["PROBE_MODEL_DIR"]? || File.expand_path("~/.llamero/models/mlx-community--gemma-3-1b-it-4bit", home: true)
model_id  = ENV["PROBE_MODEL_ID"]? || "mlx-community/gemma-3-1b-it-4bit"

bridge = Llamero::Native::MLXBridge.try_load
if bridge.nil?
  STDERR.puts "!! FATAL: MLXBridge.try_load returned nil (dylib not found/loadable)"
  exit 2
end
STDERR.puts "dylib=#{bridge.library_path}"
STDERR.puts "bridge.real?=#{bridge.real?}"

runtime = bridge.create_runtime({model_id: model_id, model_path: model_dir}.to_json)
STDERR.puts "runtime_handle=#{runtime}"
session = bridge.create_session(runtime)
STDERR.puts "session_handle=#{session}"

STDERR.puts "---- load_model raw frames ----"
bridge.load_model(session, {model_path: model_dir}.to_json) do |frame|
  STDERR.puts "FRAME #{frame.to_json}"
end

STDERR.puts "---- generate raw frames ----"
gen_req = {
  messages:    [{role: "user", content: "Reply with exactly: PROBE OK"}],
  temperature: 0.0,
  max_tokens:  32,
}.to_json
bridge.generate(session, gen_req) do |frame|
  STDERR.puts "FRAME #{frame.to_json}"
end

bridge.free_session(session)
bridge.free_runtime(runtime)
STDERR.puts "---- RAW PROBE END OK ----"
