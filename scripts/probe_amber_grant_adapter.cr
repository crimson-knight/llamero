require "../src/llamero"
require "json"
require "file_utils"

class AmberAdapterProbeTrainingPair
  include JSON::Serializable

  property prompt : String = ""
  property completion : String = ""
end

class AmberAdapterProbeProvenance
  include JSON::Serializable

  property topic : String = ""
  property prompt : String = ""
  property completion : String = ""
  property source_symbol : String = ""
end

class AmberAdapterProbeModelFile
  include JSON::Serializable

  property name : String = ""
  property lfs_sha256 : String = ""
end

class AmberAdapterProbeModelPin
  include JSON::Serializable

  property model_id : String = ""
  property pinned_model_id : String = ""
  property local_cache_relative_dir : String = ""
  property files : Array(AmberAdapterProbeModelFile) = [] of AmberAdapterProbeModelFile
end

class AmberAdapterProbeOutput
  include JSON::Serializable

  property kind : String = "generation"
  property configuration : String = ""
  property mode : String = ""
  property probe_id : String = ""
  property topic : String = ""
  property system_prompt_label : String = ""
  property system_prompt : String = ""
  property question : String = ""
  property expected_completion : String = ""
  property required_training_symbols : Array(String) = [] of String
  property matched_training_symbols : Array(String) = [] of String
  property raw_answer : String = ""
  property top_token_ids : Array(Int32) = [] of Int32
  property top_tokens : Array(String) = [] of String
  property top_logits : Array(Float64) = [] of Float64
  property baseline_top_token_ids : Array(Int32) = [] of Int32
  property baseline_top_tokens : Array(String) = [] of String
  property baseline_top_logits : Array(Float64) = [] of Float64
  property mean_absolute_logit_delta : Float64?
  property input_tokens : Int32?
  property temperature : Float32 = 0.0_f32
  property max_tokens : Int32 = 400
  property model_id : String = ""
  property model_weights_sha256 : String = ""
  property filter_id : String = ""
  property filter_weights_checksum : String = ""
  property filter_path : String = ""
  property adapter_key_remaps : Array(String) = [] of String
  property activation_events : Array(String) = [] of String
  property supported : Bool?
  property reason : String = ""

  def initialize
  end
end

record AmberAdapterProbeCase,
  id : String,
  topic : String,
  prompt : String,
  expected_completion : String,
  required_symbols : Array(String)

ROOT            = Path[__DIR__].parent
PAIR_PATH       = ROOT.join("training_data", "amber", "grant_tenancy_rawsql_pairs.jsonl")
PROVENANCE_PATH = ROOT.join("training_data", "amber", "grant_tenancy_rawsql_provenance.jsonl")
MODEL_PIN_PATH  = ROOT.join("training_data", "amber", "gemma3_4b_model_pin.json")
FILTER_PATH     = Path.home.join(".llamero", "filters", "amber-v2-0.2.0.filter")
MODEL_PATH      = Path.home.join(".llamero", "models", "mlx-community--gemma-3-4b-it-4bit")
ARTIFACT_PATH   = ROOT.join("training_data", "amber", "eval_results", "round3b-adapter-probe.jsonl")
REPORT_PATH     = ROOT.join("training_data", "amber", "eval_results", "round3b-adapter-probe.md")
EVAL_SCRIPT     = ROOT.join("scripts", "eval_amber_grant_filter.cr")
TRAIN_SCRIPT    = ROOT.join("examples", "train_amber_v2_adapter.cr")

EVAL_SYSTEM_PROMPT     = "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."
TRAINING_SYSTEM_PROMPT = "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."

PROBE_PROMPTS = [
  {"row_tenancy", "row_tenancy_declaration", "What declaration makes an invoice model filter automatically by tenant_id?", ["Grant::Base", "multitenant"] of String},
  {"row_tenancy", "row_tenancy_search", "Show a search for one tenant's invoice without repeating tenant_id in each query.", ["Grant::Base", "multitenant", "Grant::Tenant.with"] of String},
  {"raw_sql", "raw_sql_find_by_sql", "Use raw SQL to hydrate Grant Post models for one author.", ["Grant::Base", "find_by_sql"] of String},
  {"raw_sql", "raw_sql_count_by_sql", "Count matching rows with bound parameters and get an Int64 from Grant.", ["Grant::Base", "count_by_sql"] of String},
  {"schema_tenancy", "schema_tenancy_switch", "How do I run invoice queries inside the acme PostgreSQL schema?", ["Grant::Base", "Grant::SchemaTenant.with"] of String},
  {"schema_tenancy", "schema_tenancy_excluded", "Which model declaration keeps a shared plans table in public for every schema tenant?", ["Grant::Base", "schema_tenant_excluded"] of String},
]

unless EVAL_SYSTEM_PROMPT == "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."
  abort "eval system prompt changed; update the probe to match scripts/eval_amber_grant_filter.cr"
end
unless TRAINING_SYSTEM_PROMPT == "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."
  abort "training system prompt changed; update the probe to match examples/train_amber_v2_adapter.cr"
end
abort "eval source does not contain the expected system prompt" unless File.read(EVAL_SCRIPT).includes?(%Q(system_prompt = "#{EVAL_SYSTEM_PROMPT}"))
abort "training source does not contain the expected SYSTEM prompt" unless File.read(TRAIN_SCRIPT).includes?(%Q(SYSTEM         = "#{TRAINING_SYSTEM_PROMPT}"))
abort "refusing to overwrite probe artifact: #{ARTIFACT_PATH}" if File.exists?(ARTIFACT_PATH)
abort "refusing to overwrite probe report: #{REPORT_PATH}" if File.exists?(REPORT_PATH)
abort "pair corpus missing: #{PAIR_PATH}" unless File.exists?(PAIR_PATH)
abort "provenance corpus missing: #{PROVENANCE_PATH}" unless File.exists?(PROVENANCE_PATH)
abort "pinned model directory missing: #{MODEL_PATH}" unless Dir.exists?(MODEL_PATH)

pairs = [] of AmberAdapterProbeTrainingPair
File.each_line(PAIR_PATH.to_s) do |line|
  next if line.blank?
  pairs << AmberAdapterProbeTrainingPair.from_json(line)
end
provenance = [] of AmberAdapterProbeProvenance
File.each_line(PROVENANCE_PATH.to_s) do |line|
  next if line.blank?
  provenance << AmberAdapterProbeProvenance.from_json(line)
end
abort "pair/provenance row counts differ" unless pairs.size == provenance.size

probe_cases = PROBE_PROMPTS.map do |topic, id, prompt, symbols|
  pair_index = provenance.index { |row| row.topic == topic && row.prompt == prompt } ||
               abort("verbatim prompt not found in #{topic}: #{id}")
  source = provenance[pair_index]
  pair = pairs[pair_index]
  abort "pair/provenance prompt mismatch for #{id}" unless pair.prompt == source.prompt
  abort "pair/provenance completion mismatch for #{id}" unless pair.completion == source.completion
  AmberAdapterProbeCase.new(id, topic, pair.prompt, pair.completion, symbols)
end
abort "expected six unique training prompts" unless probe_cases.size == 6 && probe_cases.map(&.prompt).uniq.size == 6

pin = AmberAdapterProbeModelPin.from_json(File.read(MODEL_PIN_PATH.to_s))
weights_pin = pin.files.find { |file| file.name == "model.safetensors" } || abort("pinned model weights hash is missing")
filter = Llamero::Native::TrainingFilter.load(FILTER_PATH)
abort "expected the 0.2.0 filter, found #{filter.id}" unless filter.manifest.version == "0.2.0"
abort "expected a two-stage fuse-forward chain" unless filter.manifest.chain? && filter.manifest.stages.size == 2
abort "filter base model does not match the pinned Gemma 3 model" unless filter.manifest.base_model == pin.pinned_model_id

bridge = Llamero::Native::MLXBridge.try_load
abort "no real MLX bridge; refusing a mock probe" unless bridge
runtime = Llamero::Native::MLXRuntime.new(
  model_id: pin.pinned_model_id,
  model_path: MODEL_PATH.to_s,
  bridge: bridge
)
session = runtime.start_session
session.load_model

system_prompts = [
  {"eval", EVAL_SYSTEM_PROMPT},
  {"training", TRAINING_SYSTEM_PROMPT},
]
system_prompts_match = EVAL_SYSTEM_PROMPT == TRAINING_SYSTEM_PROMPT
activation_events = [] of Llamero::Native::AdapterActivatedEvent
session.on_event do |event|
  if activation = event.as?(Llamero::Native::AdapterActivatedEvent)
    activation_events << activation
  end
end

records = [] of AmberAdapterProbeOutput
activation_report = [] of String
FileUtils.mkdir_p(ARTIFACT_PATH.parent.to_s)
File.open(ARTIFACT_PATH.to_s, "w") do |artifact|
  system_prompts.each do |system_label, system_prompt|
    probe_cases.each do |probe_case|
      probe_id = "#{system_label}/#{probe_case.id}"
      logits = session.probe_next_token_logits(probe_id, system_prompt, probe_case.prompt, true)
      answer = session.chat(
        [Llamero::Message.system(system_prompt), Llamero::Message.user(probe_case.prompt)],
        temperature: 0.0_f32,
        max_tokens: 400
      ).content.strip

      record = AmberAdapterProbeOutput.new
      record.configuration = "base-vs-filter"
      record.mode = "base"
      record.probe_id = probe_id
      record.topic = probe_case.topic
      record.system_prompt_label = system_label
      record.system_prompt = system_prompt
      record.question = probe_case.prompt
      record.expected_completion = probe_case.expected_completion
      record.required_training_symbols = probe_case.required_symbols
      record.matched_training_symbols = probe_case.required_symbols.select do |symbol|
        Regex.new("\\b" + Regex.escape(symbol) + "\\b").matches?(answer)
      end
      record.raw_answer = answer
      record.top_token_ids = logits.top_token_ids
      record.top_tokens = logits.top_tokens
      record.top_logits = logits.top_logits
      record.input_tokens = logits.input_tokens
      record.model_id = pin.pinned_model_id
      record.model_weights_sha256 = weights_pin.lfs_sha256
      record.filter_id = filter.id
      record.filter_weights_checksum = filter.manifest.weights_checksum
      record.filter_path = FILTER_PATH.to_s
      records << record
      artifact.puts(record.to_json)
      artifact.flush
    end
  end

  session.activate_filter(filter, fuse: true)
  activation_report = activation_events.map do |event|
    "names=#{event.adapter_names.join(",")};fused=#{event.fused};cumulative=#{event.cumulative};remaps=#{event.adapter_key_remaps.join("|")}"
  end
  unless activation_events.size == filter.manifest.stages.size && activation_events.all?(&.fused) && activation_events.all?(&.cumulative)
    abort "filter activation did not report both chain stages cumulatively fused: #{activation_report.join("; ")}"
  end

  system_prompts.each do |system_label, system_prompt|
    probe_cases.each do |probe_case|
      probe_id = "#{system_label}/#{probe_case.id}"
      logits = session.probe_next_token_logits(probe_id, system_prompt, probe_case.prompt, false)
      answer = session.chat(
        [Llamero::Message.system(system_prompt), Llamero::Message.user(probe_case.prompt)],
        temperature: 0.0_f32,
        max_tokens: 400
      ).content.strip

      record = AmberAdapterProbeOutput.new
      record.configuration = "base-vs-filter"
      record.mode = "filter_fused"
      record.probe_id = probe_id
      record.topic = probe_case.topic
      record.system_prompt_label = system_label
      record.system_prompt = system_prompt
      record.question = probe_case.prompt
      record.expected_completion = probe_case.expected_completion
      record.required_training_symbols = probe_case.required_symbols
      record.matched_training_symbols = probe_case.required_symbols.select do |symbol|
        Regex.new("\\b" + Regex.escape(symbol) + "\\b").matches?(answer)
      end
      record.raw_answer = answer
      record.top_token_ids = logits.top_token_ids
      record.top_tokens = logits.top_tokens
      record.top_logits = logits.top_logits
      record.baseline_top_token_ids = logits.baseline_top_token_ids
      record.baseline_top_tokens = logits.baseline_top_tokens
      record.baseline_top_logits = logits.baseline_top_logits
      record.mean_absolute_logit_delta = logits.mean_absolute_logit_delta
      record.input_tokens = logits.input_tokens
      record.model_id = pin.pinned_model_id
      record.model_weights_sha256 = weights_pin.lfs_sha256
      record.filter_id = filter.id
      record.filter_weights_checksum = filter.manifest.weights_checksum
      record.filter_path = FILTER_PATH.to_s
      record.adapter_key_remaps = session.last_adapter_key_remaps
      record.activation_events = activation_report
      records << record
      artifact.puts(record.to_json)
      artifact.flush
    end
  end

  capability = AmberAdapterProbeOutput.new
  capability.kind = "capability"
  capability.configuration = "unfused-full-chain"
  capability.mode = "unsupported"
  capability.supported = false
  capability.filter_id = filter.id
  capability.filter_path = FILTER_PATH.to_s
  capability.reason = "This filter is a two-stage chain. ModelSession.activate_filter always reconstructs chains by cumulatively fusing each stage; the bridge rejects live stacks with more than one adapter."
  records << capability
  artifact.puts(capability.to_json)
end

runtime.close

base_records = records.select { |record| record.kind == "generation" && record.mode == "base" }
fused_records = records.select { |record| record.kind == "generation" && record.mode == "filter_fused" }
base_by_id = base_records.to_h { |record| {record.probe_id, record} }
delta_values = fused_records.compact_map(&.mean_absolute_logit_delta)
changed_logits = delta_values.count { |value| value > 0.00001 }
changed_answers = fused_records.count do |record|
  base_by_id[record.probe_id]?.try(&.raw_answer) != record.raw_answer
end
symbol_hits = fused_records.sum(&.matched_training_symbols.size)
symbol_total = fused_records.sum(&.required_training_symbols.size)
complete_symbol_cases = fused_records.count do |record|
  record.matched_training_symbols.size == record.required_training_symbols.size
end

report = String.build do |markdown|
  markdown << "# Round 3b adapter application probe\n\n"
  markdown << "- Filter: `#{filter.id}` (`#{filter.manifest.weights_checksum}`)\n"
  markdown << "- Model: `#{pin.pinned_model_id}`; weights SHA256 `#{weights_pin.lfs_sha256}`\n"
  markdown << "- Prompts: 6 verbatim training rows (2 each row tenancy, raw SQL, schema tenancy), each run under both system-prompt labels.\n"
  markdown << "- System prompts byte-equal: `#{system_prompts_match}`; both literals were checked against their source files.\n"
  markdown << "- Generation: greedy (`temperature=0`), `max_tokens=400`.\n"
  markdown << "- Chain activation events: #{activation_events.size}/#{filter.manifest.stages.size}; #{activation_report.join("; ")}\n"
  markdown << "- Full-chain unfused activation supported: `false`; the public chain path always cumulatively fuses stages, and the bridge rejects live multi-adapter stacks.\n"
  markdown << "- Fused logits changed above 1e-5 mean absolute delta: #{changed_logits}/#{fused_records.size}; mean delta range #{delta_values.min? || 0.0}–#{delta_values.max? || 0.0}.\n"
  markdown << "- Fused answers differed from base: #{changed_answers}/#{fused_records.size}. Training-symbol hits: #{symbol_hits}/#{symbol_total}; complete marker sets: #{complete_symbol_cases}/#{fused_records.size}.\n\n"
  markdown << "| System prompt | Topic | Training row | Base marker hits | Fused marker hits | Mean absolute logit delta | Top-1 changed | Answers identical |\n"
  markdown << "| --- | --- | --- | ---: | ---: | ---: | --- | --- |\n"
  fused_records.each do |fused|
    base = base_by_id[fused.probe_id]
    base_hits = "#{base.matched_training_symbols.size}/#{base.required_training_symbols.size}"
    fused_hits = "#{fused.matched_training_symbols.size}/#{fused.required_training_symbols.size}"
    delta = fused.mean_absolute_logit_delta || 0.0
    top1_changed = fused.baseline_top_token_ids.first? != fused.top_token_ids.first?
    same_answer = base.raw_answer == fused.raw_answer
    markdown << "| #{fused.system_prompt_label} | #{fused.topic} | #{fused.probe_id.split('/').last} | #{base_hits} | #{fused_hits} | #{delta.round(8)} | #{top1_changed} | #{same_answer} |\n"
  end
  markdown << "\nRaw generations, expected completions, top-five tokens, and per-prompt logits are in `round3b-adapter-probe.jsonl`.\n"
end
File.write(REPORT_PATH.to_s, report)

puts "system prompts byte-equal=#{system_prompts_match}"
puts "base/fused rows=#{base_records.size}/#{fused_records.size}; logits changed=#{changed_logits}; answers changed=#{changed_answers}"
puts "fused training-symbol hits=#{symbol_hits}/#{symbol_total}; complete rows=#{complete_symbol_cases}/#{fused_records.size}"
puts "unfused full-chain path=unsupported"
puts "artifact=#{ARTIFACT_PATH}"
puts "report=#{REPORT_PATH}"
