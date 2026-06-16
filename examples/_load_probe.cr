# Minimal load probe: does MODEL load on the current bridge, before any adapter?
#   crystal run examples/_load_probe.cr -- mlx-community/gemma-3-4b-it-4bit
require "../src/llamero"

MODEL = ARGV[0]? || abort "usage: _load_probe.cr -- <model-id>"

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found (build: cd native/llamero-mlx && ./build.sh)" unless bridge

runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
begin
  session.load_model
  puts "LOAD OK: load_count=#{session.load_count}"
  resp = session.chat([Llamero::Message.user("Reply with the single word: ok")], max_tokens: 8)
  puts "GEN OK: #{resp.content.strip.inspect}"
ensure
  runtime.close
end
