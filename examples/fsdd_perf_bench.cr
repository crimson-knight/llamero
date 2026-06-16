# FSDD performance benchmark — for ONE model per invocation.
#
#   crystal run examples/fsdd_perf_bench.cr -- mlx-community/gemma-3-1b-it-4bit
#   crystal run examples/fsdd_perf_bench.cr -- mlx-community/gemma-3-4b-it-4bit
#
# Measures, base vs. with the model's OWN matched fsdd-fs adapter:
#   - output tokens/second (generation throughput)
#   - time-to-first-token (ms)
#   - total wall time to the final output (ms)
#   - input/output token counts
#   - FSDD correctness (does it emit valid feature-story JSON)
#
# Answers: does the adapter change throughput? how does tok/s scale with model
# size? does the adapter actually work at each size? Reuses an adapter already
# trained at ~/.llamero/adapters/fsdd-fs-<model> (registers it); trains one only
# if missing. Append-writes a TSV row per condition so runs across models can be
# assembled into one table.
require "../src/llamero"
require "json"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
PAIRS = Path[__DIR__].parent.join("training_data", "fsdd_feature_story.jsonl")
ADAPTER_NAME = "fsdd-fs-#{MODEL.split('/').last.gsub(/[^A-Za-z0-9_.-]/, "-")}"
RESULTS_TSV = ENV["FSDD_PERF_TSV"]? || "/tmp/fsdd_perf_results.tsv"
MAX_TOKENS = (ENV["FSDD_PERF_MAX_TOKENS"]?.try(&.to_i?) || 400)

SYSTEM = "You are an FSDD feature-story analyst. Given a natural-language request, output ONE JSON object structuring it as a feature story: initiator (persona or scheduling), action (verb GET/POST/PUT/PATCH/DELETE for RESTful or perform/do for process/scheduling, with category), target data model or process, relationships (ActiveRecord-style), optional clauses, referenced_entities (persona/data_model/process_manager), complete + incomplete_aspects (entities referenced but not yet defined), in_scope (false if it is not a feature-story refinement request), and next_action. Output only JSON."

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

# One condition's aggregated measurements.
record Sample, tps : Float64, ttft_ms : Float64, total_ms : Float64, out_tokens : Int32, in_tokens : Int32, correct : Bool

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found (build: cd native/llamero-mlx && ./build.sh)" unless bridge

runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model
puts "loaded. load_count=#{session.load_count}"

# Ensure the model's matched adapter exists and is registered for activation.
adapter_dir = Llamero::Storage.adapters_dir.join(ADAPTER_NAME)
if Dir.exists?(adapter_dir) && !Dir.glob(adapter_dir.join("*.safetensors").to_s).empty?
  runtime.adapters.register(ADAPTER_NAME, adapter_dir)
  puts "registered existing adapter: #{adapter_dir}"
else
  puts "no adapter on disk — training #{ADAPTER_NAME} first..."
  dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
    PAIRS, system_prompt: SYSTEM, format: Llamero::Native::TrainingDataset.template_for(MODEL)
  )
  cfg = Llamero::Native::AdapterTrainingConfig.new
  cfg.iterations = (ENV["FSDD_ITERS"]?.try(&.to_i?) || 400)
  cfg.batch_size = (ENV["FSDD_BATCH"]?.try(&.to_i?) || 2)
  cfg.num_layers = (ENV["FSDD_LAYERS"]?.try(&.to_i?) || cfg.num_layers)
  cfg.learning_rate = 1e-4
  session.train_adapter(ADAPTER_NAME, dataset, cfg) do |p|
    puts "  iter #{p.iteration}/#{p.total_iterations}: loss=#{p.loss.round(3)}" if p.iteration % 50 == 0
  end
  puts "trained -> #{adapter_dir}"
end

# Run every probe once and aggregate the bridge's per-generation metrics.
# A warmup generation is discarded first (graph build / cache warm skews tok/s).
measure = ->(label : String) do
  session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user("warmup")], max_tokens: 16)

  tps = [] of Float64
  ttft = [] of Float64
  total = 0.0
  out_tok = 0
  in_tok = 0
  correct = 0
  PROBES.each do |request, check|
    resp = session.chat([Llamero::Message.system(SYSTEM), Llamero::Message.user(request)], max_tokens: MAX_TOKENS)
    m = resp.metrics
    tps << m.tokens_per_second
    ttft << m.time_to_first_token_ms
    total += m.total_time_ms
    out_tok += m.output_tokens
    in_tok += m.input_tokens
    text = resp.content.gsub(/<think>.*?<\/think>/m, "").strip
    parsed = parse_json(text)
    ok = parsed ? (check.call(parsed) rescue false) : false
    correct += 1 if ok
    puts "  [#{ok ? "PASS" : "miss"}] #{m.tokens_per_second.round(1)} tok/s  ttft=#{m.time_to_first_token_ms.round(0)}ms  out=#{m.output_tokens}  | #{request}"
  end
  mean_tps = tps.sum / tps.size
  mean_ttft = ttft.sum / ttft.size
  puts "[#{label}]  mean #{mean_tps.round(1)} tok/s | mean ttft #{mean_ttft.round(0)}ms | total #{(total / 1000).round(2)}s | out #{out_tok} tok | correct #{correct}/#{PROBES.size}"
  Sample.new(mean_tps, mean_ttft, total, out_tok, in_tok, correct == PROBES.size)
end

puts "\n--- BASE (no adapter) ---"
base = measure.call("base")

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new(ADAPTER_NAME)])
)
puts "\n--- WITH #{ADAPTER_NAME} (load_count=#{session.load_count}) ---"
adapted = measure.call("adapter")

runtime.close

overhead = ((base.tps - adapted.tps) / base.tps * 100)
puts "\n=== #{MODEL} ==="
puts "base    : #{base.tps.round(1)} tok/s  ttft #{base.ttft_ms.round(0)}ms  total #{(base.total_ms/1000).round(2)}s  correct #{base.correct}"
puts "adapter : #{adapted.tps.round(1)} tok/s  ttft #{adapted.ttft_ms.round(0)}ms  total #{(adapted.total_ms/1000).round(2)}s  correct #{adapted.correct}"
puts "adapter throughput overhead vs base: #{overhead.round(1)}%  (load_count=#{session.load_count}, expect 1)"

# Append machine-readable rows for cross-model table assembly.
File.open(RESULTS_TSV, "a") do |f|
  f.puts "#{MODEL}\tbase\t#{base.tps.round(2)}\t#{base.ttft_ms.round(1)}\t#{base.total_ms.round(1)}\t#{base.out_tokens}\t#{base.correct}"
  f.puts "#{MODEL}\tadapter\t#{adapted.tps.round(2)}\t#{adapted.ttft_ms.round(1)}\t#{adapted.total_ms.round(1)}\t#{adapted.out_tokens}\t#{adapted.correct}"
end
puts "appended -> #{RESULTS_TSV}"
