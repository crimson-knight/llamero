require "../src/llamero"
require "../src/native/amber_compile_judge"
require "json"
require "file_utils"
require "set"

class AmberGrantEvalCase
  include JSON::Serializable

  property kind : String = "eval"
  property id : String = ""
  property topic : String = ""
  property question : String = ""
  property required_symbols : Array(String) = [] of String
  property compile_mode : String = "direct"

  def initialize(
    @kind : String,
    @id : String,
    @topic : String,
    @question : String,
    @required_symbols : Array(String),
    @compile_mode : String = "direct",
  )
  end
end

class AmberGrantEvalPrompt
  include JSON::Serializable

  property prompt : String = ""
end

class AmberGrantModelPinFile
  include JSON::Serializable

  property name : String = ""
  property lfs_sha256 : String = ""
end

class AmberGrantModelPin
  include JSON::Serializable

  property model_id : String = ""
  property pinned_model_id : String = ""
  property revision : String = ""
  property local_cache_relative_dir : String = ""
  property files : Array(AmberGrantModelPinFile) = [] of AmberGrantModelPinFile
end

class AmberGrantEvalRecord
  include JSON::Serializable

  property phase : String = ""
  property model_id : String = ""
  property filter_id : String = ""
  property filter_base_model : String = ""
  property filter_weights_checksum : String = ""
  property source_filter_weights_checksum : String = ""
  property adapter_key_remap : String = "none"
  property generation_temperature : Float32 = 0.0_f32
  property weights_sha256 : String = ""
  property id : String = ""
  property cohort : String = ""
  property topic : String = ""
  property question : String = ""
  property raw_answer : String = ""
  property code : String = ""
  property compile_mode : String = "direct"
  property compiled : Bool = false
  property compiler_output : String = ""
  property required_symbols : Array(String) = [] of String
  property found_symbols : Array(String) = [] of String
  property missing_symbols : Array(String) = [] of String

  def initialize(
    @phase : String,
    @model_id : String,
    @filter_id : String,
    @filter_base_model : String,
    @filter_weights_checksum : String,
    @source_filter_weights_checksum : String,
    @adapter_key_remap : String,
    @generation_temperature : Float32,
    @weights_sha256 : String,
    @id : String,
    @cohort : String,
    @topic : String,
    @question : String,
    @raw_answer : String,
    @code : String,
    @compile_mode : String,
    @compiled : Bool,
    @compiler_output : String,
    @required_symbols : Array(String),
    @found_symbols : Array(String),
    @missing_symbols : Array(String),
  )
  end
end

ROOT                = Path[__DIR__].parent
EVAL_PATH           = Path[ENV["AMBER_GRANT_EVAL_PATH"]? || ROOT.join("training_data", "amber", "grant_tenancy_eval.jsonl").to_s].expand
CORPUS_PATH         = ROOT.join("training_data", "amber", "amber_v2_sft.jsonl")
PIN_PATH            = ROOT.join("training_data", "amber", "gemma3_4b_model_pin.json")
GRANT_ROOT          = ROOT.join(".crystal-cache", "grant-c6b5e72")
AMBER_ROOT          = ROOT.join(".crystal-cache", "amber-f2a1490")
OLD_AMBER_QUESTIONS = [
  AmberGrantEvalCase.new(
    "eval", "amber_heldout_route", "routing",
    "Write only Crystal route code for inside `routes :web do ... end`: map GET /users to UsersController#index.",
    ["routes :web", "get", "UsersController"], "routes_web"
  ),
  AmberGrantEvalCase.new(
    "eval", "amber_heldout_channel", "websockets",
    "Define a Crystal Amber channel that broadcasts a welcome event after a client joins.",
    ["Amber::WebSockets::Channel", "after_join", "broadcast!"], "direct"
  ),
  AmberGrantEvalCase.new(
    "eval", "amber_heldout_schema", "schema",
    "Define an Amber schema with a required email string field and email format validation.",
    ["Amber::Schema::Definition", "field", "format"], "direct"
  ),
  AmberGrantEvalCase.new(
    "eval", "amber_heldout_job", "jobs",
    "Define an Amber job with at most three retries and enqueue it to run after five minutes.",
    ["Amber::Jobs::Job", "max_retries", "enqueue", "delay"], "direct"
  ),
  AmberGrantEvalCase.new(
    "eval", "amber_heldout_controller", "controllers",
    "Define an Amber controller with a before_action that authenticates before the show action.",
    ["Amber::Controller::Base", "before_action", "authenticate!"], "direct"
  ),
]

phase = ARGV[0]? || abort("Usage: crystal-alpha run scripts/eval_amber_grant_filter.cr -- <before|after> <filter_path> <output.jsonl>")
filter_path = ARGV[1]? || abort("filter path is required")
output_path = Path[ARGV[2]? || abort("output path is required")].expand
validate_only = ARGV[3]? == "--validate-only"
unless phase == "before" || phase == "after" || phase.starts_with?("round3b-")
  abort "phase must be before, after, or round3b-<configuration>-run-<number>"
end
abort "refusing to overwrite eval artifact: #{output_path}" if File.exists?(output_path) && !validate_only
abort "held-out Grant eval is missing: #{EVAL_PATH}" unless File.exists?(EVAL_PATH)
abort "merged SFT corpus is missing: #{CORPUS_PATH}" unless File.exists?(CORPUS_PATH)

pin = AmberGrantModelPin.from_json(File.read(PIN_PATH.to_s))
weights_pin = pin.files.find { |item| item.name == "model.safetensors" }
abort "pinned model weights SHA256 is missing" unless weights_pin
model_id = pin.pinned_model_id
model_path = Path.home.join(".llamero", "models", pin.local_cache_relative_dir)
filter = Llamero::Native::TrainingFilter.load(filter_path)
source_filter_weights_checksum = ENV["AMBER_SOURCE_FILTER_WEIGHTS_SHA256"]? || filter.manifest.weights_checksum
if phase == "before" && filter.manifest.version != "0.1.0"
  abort "before eval requires the installed 0.1.0 filter; got #{filter.manifest.id}"
end
if phase == "after" && filter.manifest.version != "0.2.0"
  abort "after eval requires filter version 0.2.0; got #{filter.manifest.id}"
end
unless [pin.model_id, pin.pinned_model_id].includes?(filter.manifest.base_model)
  abort "filter base mismatch: expected #{pin.model_id} or #{pin.pinned_model_id}; got #{filter.manifest.base_model}"
end
unless filter.manifest.lora.rank == 8 && filter.manifest.lora.num_layers == 16
  abort "filter LoRA shape mismatch: expected rank 8 across 16 layers"
end
unless filter.manifest.stages.size == 2
  abort "expected the installed two-stage Amber V2 filter; got #{filter.manifest.stages.size} stages"
end

def read_eval_cases(path : Path) : Array(AmberGrantEvalCase)
  cases = [] of AmberGrantEvalCase
  File.each_line(path.to_s) do |line|
    next if line.blank?
    cases << AmberGrantEvalCase.from_json(line)
  end
  cases
end

def read_corpus_prompts(path : Path) : Array(String)
  prompts = [] of String
  File.each_line(path.to_s) do |line|
    next if line.blank?
    prompts << AmberGrantEvalPrompt.from_json(line).prompt
  end
  prompts
end

def normalized_prompt(prompt : String) : String
  prompt.downcase.gsub(/\s+/, " ").strip
end

def prompt_tokens(prompt : String) : Set(String)
  prompt.downcase.split(/[^a-z0-9_]+/).reject(&.empty?).to_set
end

def token_jaccard(left : String, right : String) : Float64
  left_tokens = prompt_tokens(left)
  right_tokens = prompt_tokens(right)
  union_size = (left_tokens | right_tokens).size
  return 0.0 if union_size == 0
  (left_tokens & right_tokens).size.to_f / union_size
end

def contains_symbol?(text : String, symbol : String) : Bool
  Regex.new("\\b" + Regex.escape(symbol) + "\\b").matches?(text)
end

def compile_source(code : String, compile_mode : String) : String
  return code unless compile_mode == "routes_web" || compile_mode == "amber_pipeline"

  String.build do |source|
    if compile_mode == "routes_web"
      source << "class UsersController < Amber::Controller::Base\n"
      source << "  def index\n  end\nend\n\n"
      source << "Amber::Server.configure do\n  routes :web do\n#{code}\n  end\nend"
    else
      source << "class TenantPipe\n"
      source << "  include HTTP::Handler\n"
      source << "  def call(context : HTTP::Server::Context)\n    call_next(context)\n  end\nend\n\n"
      source << "Amber::Server.configure do\n  pipeline :web do\n#{code}\n  end\nend"
    end
  end
end

def short_compiler_output(output : String) : String
  output.size > 4000 ? output[0, 4000] : output
end

grant_cases = read_eval_cases(EVAL_PATH)
unless (15..60).includes?(grant_cases.size)
  abort "held-out Grant eval needs 15-60 cases; found #{grant_cases.size}"
end
all_cases = grant_cases + OLD_AMBER_QUESTIONS
corpus_prompts = read_corpus_prompts(CORPUS_PATH)
all_cases.each do |test_case|
  normalized = normalized_prompt(test_case.question)
  if corpus_prompts.any? { |prompt| normalized_prompt(prompt) == normalized }
    abort "held-out prompt is an exact duplicate of training: #{test_case.id}"
  end
  if corpus_prompts.any? { |prompt| token_jaccard(test_case.question, prompt) >= 0.8 }
    abort "held-out prompt is a near duplicate of training: #{test_case.id}"
  end
end

judge = Llamero::Native::AmberCompileJudge.new(
  amber_root: AMBER_ROOT.to_s,
  grant_root: GRANT_ROOT.to_s,
  work_dir: ROOT.join(".crystal-cache", "amber-grant-eval-judge")
)
route_probe = compile_source("get \"/users\", UsersController, :index", "routes_web")
pipeline_probe = compile_source(
  "plug Amber::Pipe::Session.new\nplug TenantPipe.new\nplug Amber::Pipe::CSRF.new",
  "amber_pipeline"
)
abort "route eval harness does not compile:\n#{judge.last_output}" unless judge.compile?(route_probe)
abort "pipeline eval harness does not compile:\n#{judge.last_output}" unless judge.compile?(pipeline_probe)
puts "Amber compile harness probes: 2/2"
puts "held-out prompt overlap check: #{all_cases.size} questions checked against #{corpus_prompts.size} training prompts"
exit if validate_only

bridge = Llamero::Native::MLXBridge.try_load
abort "no MLX bridge; refusing to score mock output" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: filter.manifest.base_model, model_path: model_path.to_s, bridge: bridge)
session = runtime.start_session
session.load_model
session.activate_filter(filter, fuse: true)

system_prompt = "You are an expert Amber V2 and Grant developer. Answer with correct, idiomatic Crystal code."

FileUtils.mkdir_p(output_path.parent.to_s)
compiled_count = 0
symbol_count = 0
symbol_case_count = 0
File.open(output_path.to_s, "w") do |artifact|
  all_cases.each_with_index do |test_case, index|
    raw_answer = session.chat(
      [Llamero::Message.system(system_prompt), Llamero::Message.user(test_case.question)],
      temperature: 0.0_f32,
      max_tokens: 600
    ).content.strip
    code = Llamero::Native::RL.extract_code(raw_answer).strip
    compiler_input = compile_source(code, test_case.compile_mode)
    compiles = judge.compile?(compiler_input)
    compiler_output = short_compiler_output(judge.last_output)
    found_symbols = test_case.required_symbols.select { |symbol| contains_symbol?(code, symbol) }
    missing_symbols = test_case.required_symbols - found_symbols
    compiled_count += 1 if compiles
    symbol_count += 1 if missing_symbols.empty?
    symbol_case_count += 1 unless test_case.required_symbols.empty?

    record = AmberGrantEvalRecord.new(
      phase: phase,
      model_id: model_id,
      filter_id: filter.id,
      filter_base_model: filter.manifest.base_model,
      filter_weights_checksum: filter.manifest.weights_checksum,
      source_filter_weights_checksum: source_filter_weights_checksum,
      adapter_key_remap: session.last_adapter_key_remaps.join(","),
      generation_temperature: 0.0_f32,
      weights_sha256: weights_pin.lfs_sha256,
      id: test_case.id,
      cohort: test_case.topic == "routing" || test_case.topic == "websockets" || test_case.topic == "schema" || test_case.topic == "jobs" || test_case.topic == "controllers" ? "amber_regression" : "grant_heldout",
      topic: test_case.topic,
      question: test_case.question,
      raw_answer: raw_answer,
      code: code,
      compile_mode: test_case.compile_mode,
      compiled: compiles,
      compiler_output: compiler_output,
      required_symbols: test_case.required_symbols,
      found_symbols: found_symbols,
      missing_symbols: missing_symbols,
    )
    artifact.puts(record.to_json)
    artifact.flush
    puts "#{index + 1}/#{all_cases.size} #{test_case.id}: compile=#{compiles} symbols=#{found_symbols.size}/#{test_case.required_symbols.size}"
    unless compiles
      puts short_compiler_output(compiler_output)
    end
  end
end

runtime.close
puts "compile rate: #{compiled_count}/#{all_cases.size}"
puts "required-symbol complete cases: #{symbol_count}/#{symbol_case_count}"
puts "artifact: #{output_path}"
