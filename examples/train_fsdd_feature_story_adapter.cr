# FSDD Stage 1 proof: teach a small Gemma its ROLE when creating/managing
# feature stories under Feature-Story-Driven Development.
#
#   crystal run examples/train_fsdd_feature_story_adapter.cr
#   crystal run examples/train_fsdd_feature_story_adapter.cr -- mlx-community/gemma-3-4b-it-4bit
#
# Trains a QLoRA adapter so the model takes a natural-language request and emits
# the structured feature-story JSON (initiator/persona-or-scheduling, action verb
# + category, target data model/process, relationships, clauses, referenced
# entities, completeness + incomplete aspects, in-scope gating, next action).
# Use a DENSE base (gemma-3-1b / gemma-3-4b). The Gemma e-series (e2b/e4b) trains
# but its adapter has no inference effect — do NOT use it here.
require "../src/llamero"
require "json"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
PAIRS = Path[__DIR__].parent.join("training_data", "fsdd_feature_story.jsonl")

# A LoRA adapter is bound to the exact base model it was trained on — its tensor
# shapes and layer keys only match that one checkpoint, so adapters NEVER work
# cross-model. Derive a per-model adapter name so every model trains and loads
# its OWN matching adapter (and sequential runs can't collide on disk).
ADAPTER_NAME = "fsdd-fs-#{MODEL.split('/').last.gsub(/[^A-Za-z0-9_.-]/, "-")}"
SYSTEM = "You are an FSDD feature-story analyst. Given a natural-language request, output ONE JSON object structuring it as a feature story: initiator (persona or scheduling), action (verb GET/POST/PUT/PATCH/DELETE for RESTful or perform/do for process/scheduling, with category), target data model or process, relationships (ActiveRecord-style), optional clauses, referenced_entities (persona/data_model/process_manager), complete + incomplete_aspects (entities referenced but not yet defined), in_scope (false if it is not a feature-story refinement request), and next_action. Output only JSON."

# Held-out probes: (request, checker on the parsed JSON). The base model rarely
# gets the FSDD-specific structure (verb category, scope gating, completeness)
# right; the adapter should.
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
  s = text.index('{')
  e = text.rindex('}')
  return nil unless s && e && e > s
  JSON.parse(text[s..e])
rescue
  nil
end

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found (build: cd native/llamero-mlx && ./build.sh)" unless bridge

runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} (downloads if missing)..."
session.load_model
puts "loaded. load_count=#{session.load_count}"

ask = ->(request : String) do
  resp = session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(request)], max_tokens: 400)
  resp.content.gsub(/<think>.*?<\/think>/m, "").strip
end

score = ->(label : String) do
  hits = 0
  PROBES.each do |request, check|
    answer = ask.call(request)
    parsed = parse_json(answer)
    ok = parsed ? (check.call(parsed) rescue false) : false
    hits += 1 if ok
    puts "  [#{ok ? "PASS" : "miss"}] #{request}"
    puts "         -> #{answer[0, 150].gsub('\n', ' ')}"
  end
  puts "[#{label}] #{hits}/#{PROBES.size} probes produced correct FSDD structure"
  hits
end

puts "\n--- before training ---"
before = score.call("base model")

dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
  PAIRS, system_prompt: SYSTEM, format: Llamero::Native::TrainingDataset.template_for(MODEL)
)
puts "\ndataset: #{dataset.size} pairs from #{PAIRS}"

config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = (ENV["FSDD_ITERS"]?.try(&.to_i?) || 400)
config.batch_size = 2
config.learning_rate = 1e-4
config.steps_per_report = 50
config.steps_per_eval = 100

puts "training '#{ADAPTER_NAME}' on #{MODEL} (#{config.iterations} iters)..."
descriptor = session.train_adapter(ADAPTER_NAME, dataset, config) do |p|
  puts "  iter #{p.iteration}/#{p.total_iterations}: loss=#{p.loss.round(3)} (#{p.tokens_per_second.round(0)} tok/s)"
end
summary = session.last_training.not_nil!
puts "trained in #{(summary.total_time_ms / 1000).round(1)}s, final loss=#{summary.final_loss.round(3)} -> #{descriptor.path}"

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new(ADAPTER_NAME)])
)
puts "\n--- with #{ADAPTER_NAME} adapter ---"
with_adapter = score.call("adapter active")

session.deactivate_adapters
puts "\n--- adapter removed ---"
after = score.call("base again")

puts "\n--- results ---  load_count=#{session.load_count} (expect 1)"
runtime.close
if with_adapter > before && with_adapter >= 3
  puts "FSDD FEATURE-STORY ADAPTER TEST PASSED (before=#{before} with=#{with_adapter} after=#{after})"
else
  abort "FSDD FEATURE-STORY ADAPTER TEST FAILED (before=#{before} with=#{with_adapter} after=#{after})"
end
