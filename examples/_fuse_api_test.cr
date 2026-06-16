# End-to-end validation of the activate_adapters(stack, fuse:) API.
#   crystal run examples/_fuse_api_test.cr -- mlx-community/gemma-3-4b-it-4bit
#
# Proves: fuse:true gives full base throughput AND preserves correctness, does
# NOT reload (load_count stays 1), sets active_adapters_fused?, and that
# deactivating a fused adapter transparently reloads the base (load_count ++,
# base behavior restored). Reuses the on-disk fsdd-fs-<model> adapter.
require "../src/llamero"
require "json"

MODEL = ARGV[0]? || "mlx-community/gemma-3-4b-it-4bit"
ADAPTER = "fsdd-fs-#{MODEL.split('/').last.gsub(/[^A-Za-z0-9_.-]/, "-")}"
SYSTEM = "You are an FSDD feature-story analyst. Given a natural-language request, output ONE JSON object structuring it as a feature story: initiator (persona or scheduling), action (verb GET/POST/PUT/PATCH/DELETE for RESTful or perform/do for process/scheduling, with category), target data model or process, relationships (ActiveRecord-style), optional clauses, referenced_entities (persona/data_model/process_manager), complete + incomplete_aspects (entities referenced but not yet defined), in_scope (false if it is not a feature-story refinement request), and next_action. Output only JSON."
NEUTRAL = "Write a long, detailed description of a walk through a forest in autumn. Keep going with vivid sensory detail."

PROBES = [
  {"an editor can publish an article",
   ->(j : JSON::Any) { j["in_scope"]?.try(&.as_bool?) == true && j["action"]?.try(&.["category"]?).try(&.as_s?) == "restful" }},
  {"every night at 11pm do PurgeExpiredSessions",
   ->(j : JSON::Any) { j["initiator"]?.try(&.["type"]?).try(&.as_s?) == "scheduling" && j["complete"]?.try(&.as_bool?) == false }},
  {"as a guest, view the available subscription plans",
   ->(j : JSON::Any) { j["in_scope"]?.try(&.as_bool?) == true && j["action"]?.try(&.["verb"]?).try(&.as_s?) == "GET" }},
  {"please refactor the payment service for me",
   ->(j : JSON::Any) { j["in_scope"]?.try(&.as_bool?) == false }},
]

def parse_json(text : String) : JSON::Any?
  s = text.index('{'); e = text.rindex('}')
  return nil unless s && e && e > s
  JSON.parse(text[s..e])
rescue
  nil
end

bridge = Llamero::Native::MLXBridge.try_load
abort "no bridge" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
session.load_model
dir = Llamero::Storage.adapters_dir.join(ADAPTER)
abort "adapter missing: #{dir}" unless Dir.exists?(dir)
runtime.adapters.register(ADAPTER, dir)

tput = ->do
  session.chat([Llamero::Message.user("warmup")], max_tokens: 8)
  t = [] of Float64
  3.times { t << session.chat([Llamero::Message.user(NEUTRAL)], max_tokens: 256).metrics.tokens_per_second }
  (t.sum / t.size).round(1)
end
correct = ->do
  hits = 0
  PROBES.each do |req, check|
    r = session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(req)], max_tokens: 400)
    parsed = parse_json(r.content.gsub(/<think>.*?<\/think>/m, "").strip)
    hits += 1 if parsed && (check.call(parsed) rescue false)
  end
  hits
end
stack = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new(ADAPTER)])

puts "=== #{MODEL} : activate_adapters(fuse:) validation ==="
b_tps = tput.call; b_ok = correct.call
puts "BASE       tps=#{b_tps} correct=#{b_ok}/4 load_count=#{session.load_count} fused?=#{session.active_adapters_fused?}"

session.activate_adapters(stack, fuse: true)
lc_after_fuse = session.load_count
fused_flag = session.active_adapters_fused?
f_tps = tput.call; f_ok = correct.call
puts "FUSED      tps=#{f_tps} correct=#{f_ok}/4 load_count=#{lc_after_fuse} fused?=#{fused_flag}"

session.deactivate_adapters
lc_after_deact = session.load_count
deact_flag = session.active_adapters_fused?
d_tps = tput.call; d_ok = correct.call
puts "DEACTIVATED tps=#{d_tps} correct=#{d_ok}/4 load_count=#{lc_after_deact} fused?=#{deact_flag}"

runtime.close

checks = {
  "fuse set the fused flag"             => (fused_flag == true),
  "fuse did NOT reload (load_count==1)" => (lc_after_fuse == 1),
  "fused recovers throughput (>=0.9x base)" => (f_tps >= b_tps * 0.9),
  "fused preserves correctness (>=3/4)" => (f_ok >= 3),
  "deactivate cleared fused flag"       => (deact_flag == false),
  "deactivate reloaded base (load_count==2)" => (lc_after_deact == 2),
  "deactivate restored base behavior (0/4)"  => (d_ok == 0),
}
puts "\n--- checks ---"
checks.each { |k, v| puts "  [#{v ? "PASS" : "FAIL"}] #{k}" }
if checks.values.all?
  puts "\nFUSE API TEST PASSED"
else
  abort "\nFUSE API TEST FAILED"
end
