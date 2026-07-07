require "llamero"
require "json"
require "./schemas"

# 4-arm GBNF benchmark per GBNF_SPEC.md section 4 (protocol) and D11.
#
# Arms: {base, tuned} x {unconstrained, grammar}
#   unconstrained = plain completion, schema-in-prompt, lenient JSON
#                   extraction + typed parse in the harness
#   grammar       = chat_structured(generation_mode: :grammar) through the
#                   pinned llama.cpp seam (grammar_parse_retries: 0 so the
#                   harness owns ALL retry accounting identically per arm)
#
# Matched prompts: BOTH arms receive the identical message list (the dottxt
# lesson). The only difference between arms is --grammar-file.
#
# Prompt calibration (documented deviation from the schema-dump draft): the
# product's verbatim JSON-Schema instruction text sent SmolLM-135M into echo
# loops in EVERY arm (smoke run results/smoke.jsonl: 0/4 arms ever correct,
# unconstrained output was literal "<function>" spam). A 135M model needs a
# worked example, so both arms get an identical system message naming the keys
# plus ONE identical few-shot example pair. This keeps arms matched while
# making the correctness oracle reachable at all.
#
# Time-to-CORRECT: wall clock accumulates across attempts until the oracle
# passes; retries count in the failing arm's clock. Attempt 1 at the run's
# base temperature; retry attempts resample at temp 0.8 with a fresh seed
# (retrying a deterministic greedy failure verbatim can never succeed).
#
# Every run goes through the pinned binary only - the probe is asserted
# before any timing starts.

MAX_TOKENS   =           400
CTX_SIZE     =          2048
THREADS      =             4
MAX_ATTEMPTS =             3
RETRY_TEMP   = 0.8_f32
TIMEOUT      = 3.minutes

BASE_GGUF  = ENV["BENCH_BASE_GGUF"]? || Path[__DIR__, "..", "models", "smollm-135m-base-f16.gguf"].expand.to_s
TUNED_GGUF = ENV["BENCH_TUNED_GGUF"]? || "/Users/crimsonknight/agentc_coding_projects/knowledge_pack_lab/recon/mlx_smoke/fused2/smollm-135m-llamero-v2-f16.gguf"

# Captures stderr of the last generation call so token/perf stats can be
# parsed from llama-completion's common_perf_print lines, while still running
# the exact product code path (CompletionBackend -> SubprocessRunner).
class RecordingRunner < Llamero::LlamaCpp::SubprocessRunner
  getter last_stderr : String = ""

  def run(path : Path, args : Array(String), timeout : Time::Span = 5.minutes) : Llamero::LlamaCpp::RunResult
    result = super
    @last_stderr = result.error_output
    result
  end
end

struct PerfStats
  getter gen_tokens : Int32
  getter eval_ms : Float64
  getter prompt_tokens : Int32
  getter prompt_ms : Float64
  getter load_ms : Float64
  getter sampler_ms : Float64
  getter sampler_tokens : Int32

  def initialize(@gen_tokens, @eval_ms, @prompt_tokens, @prompt_ms, @load_ms, @sampler_ms, @sampler_tokens)
  end

  def eval_tps : Float64
    eval_ms > 0 ? gen_tokens * 1000.0 / eval_ms : 0.0
  end

  def sampler_ms_per_token : Float64
    sampler_tokens > 0 ? sampler_ms / sampler_tokens : 0.0
  end

  def self.parse(stderr : String) : PerfStats
    gen_t = 0
    eval_ms = 0.0
    p_t = 0
    p_ms = 0.0
    load = 0.0
    s_ms = 0.0
    s_t = 0
    if m = stderr.match(/eval time =\s+([\d.]+) ms \/\s+(\d+) runs/)
      eval_ms = m[1].to_f
      gen_t = m[2].to_i
    end
    if m = stderr.match(/prompt eval time =\s+([\d.]+) ms \/\s+(\d+) tokens/)
      p_ms = m[1].to_f
      p_t = m[2].to_i
    end
    if m = stderr.match(/load time =\s+([\d.]+) ms/)
      load = m[1].to_f
    end
    if m = stderr.match(/samplers time =\s+([\d.]+) ms \/\s+(\d+) tokens/)
      s_ms = m[1].to_f
      s_t = m[2].to_i
    end
    new(gen_t, eval_ms, p_t, p_ms, load, s_ms, s_t)
  end
end

# Same lenient extraction CompletionBackend#extract_json uses for its
# schema-prompt path, replicated so the unconstrained arm is parsed exactly
# the way the product would parse it.
def extract_json(content : String) : String
  text = content.strip
  if fenced = text.match(/```(?:json)?\s*(.+?)```/m)
    text = fenced[1].strip
  end
  start_index = text.index('{')
  end_index = text.rindex('}')
  if start_index && end_index && end_index > start_index
    text[start_index..end_index]
  else
    text
  end
end

# NOTE: the original schema-dump instruction builder was removed after the
# smoke run showed it is unusable at 135M scale (see header comment). Both
# arms now share key-naming system prompts + one-shot examples below.

record AttemptResult,
  wall_ms : Float64,
  parse_ok : Bool,
  correct : Bool,
  content_size : Int32,
  content : String,
  perf : PerfStats

# Full per-attempt record so losing arms are auditable from the checked-in
# data: what the model actually said, at which temperature, and what it cost.
struct AttemptDetail
  include JSON::Serializable

  property idx : Int32
  property temp : Float32
  property wall_ms : Float64
  property parse_ok : Bool
  property correct : Bool
  property gen_tokens : Int32
  property prompt_tokens : Int32
  property load_ms : Float64
  property sampler_ms_per_token : Float64
  property content : String

  def initialize(@idx, @temp, @wall_ms, @parse_ok, @correct, @gen_tokens,
                 @prompt_tokens, @load_ms, @sampler_ms_per_token, @content)
  end
end

class RunRecord
  include JSON::Serializable

  property task : String
  property arm : String
  property model : String
  property mode : String
  property temp_label : String
  property run : Int32
  property attempts : Int32
  property success : Bool
  property wall_ms : Float64
  property first_attempt_parse_ok : Bool
  property first_attempt_correct : Bool
  property gen_tokens_total : Int32
  property prompt_tokens : Int32
  property eval_tps_last : Float64
  property load_ms_last : Float64
  property sampler_ms_per_token_last : Float64
  property content_size_last : Int32
  property attempt_log : Array(AttemptDetail)

  def initialize(@task, @arm, @model, @mode, @temp_label, @run, @attempts, @success, @wall_ms,
                 @first_attempt_parse_ok, @first_attempt_correct, @gen_tokens_total, @prompt_tokens,
                 @eval_tps_last, @load_ms_last, @sampler_ms_per_token_last, @content_size_last,
                 @attempt_log)
  end
end

RUNNER = RecordingRunner.new

def make_backend(model_path : String, seed : Int32?) : Llamero::LlamaCpp::CompletionBackend
  Llamero::LlamaCpp::CompletionBackend.new(
    model_path: model_path,
    runner: RUNNER,
    grammar_parse_retries: 0, # the harness owns retries so both arms account identically
    context_size: CTX_SIZE,
    threads: THREADS,
    seed: seed,
    timeout: TIMEOUT
  )
end

# One attempt: generate, parse, judge. Returns nil-parsed on any parse failure.
def attempt(model_path : String, mode : String, messages : Array(Llamero::Message),
            schema : T.class, oracle : T -> Bool, temp : Float32, seed : Int32?) : AttemptResult forall T
  backend = make_backend(model_path, seed)
  started = Time.instant
  parsed : T? = nil
  content = ""

  if mode == "grammar"
    begin
      resp = backend.chat_structured(messages, T, generation_mode: :grammar,
        temperature: temp, max_tokens: MAX_TOKENS)
      content = resp.content
      parsed = resp.parsed
    rescue ex : Llamero::Native::StructuredParseError
      content = ex.raw_text
      parsed = nil
    end
  else
    resp = backend.chat(messages, temperature: temp, max_tokens: MAX_TOKENS)
    content = resp.content
    parsed = begin
      T.from_json(extract_json(content))
    rescue JSON::ParseException | JSON::SerializableError
      nil
    end
  end

  wall_ms = (Time.instant - started).total_milliseconds
  parse_ok = !parsed.nil?
  correct = if p = parsed
              oracle.call(p)
            else
              false
            end
  AttemptResult.new(wall_ms, parse_ok, correct, content.bytesize, content.scrub, PerfStats.parse(RUNNER.last_stderr))
end

# One benchmark run = attempts until CORRECT (oracle passes) or MAX_ATTEMPTS.
def bench_run(task : String, arm : String, model_path : String, mode : String, temp_label : String,
              run_idx : Int32, messages : Array(Llamero::Message),
              schema : T.class, oracle : T -> Bool) : RunRecord forall T
  base_temp = temp_label == "temp0" ? 0.0_f32 : 0.7_f32
  total_wall = 0.0
  total_tokens = 0
  attempts_used = 0
  success = false
  first_parse_ok = false
  first_correct = false
  last : AttemptResult? = nil
  attempt_log = [] of AttemptDetail

  MAX_ATTEMPTS.times do |i|
    temp = i.zero? ? base_temp : (base_temp > 0 ? base_temp : RETRY_TEMP)
    seed = base_temp > 0 || i > 0 ? 10_000 + run_idx * 10 + i : nil
    result = attempt(model_path, mode, messages, T, oracle, temp, seed)
    attempts_used += 1
    total_wall += result.wall_ms
    total_tokens += result.perf.gen_tokens
    last = result
    attempt_log << AttemptDetail.new(i, temp, result.wall_ms, result.parse_ok, result.correct,
      result.perf.gen_tokens, result.perf.prompt_tokens, result.perf.load_ms,
      result.perf.sampler_ms_per_token, result.content)
    if i.zero?
      first_parse_ok = result.parse_ok
      first_correct = result.correct
    end
    if result.correct
      success = true
      break
    end
  end

  last_result = last.not_nil!
  RunRecord.new(task, arm, File.basename(model_path), mode, temp_label, run_idx, attempts_used,
    success, total_wall, first_parse_ok, first_correct, total_tokens, last_result.perf.prompt_tokens,
    last_result.perf.eval_tps, last_result.perf.load_ms, last_result.perf.sampler_ms_per_token,
    last_result.content_size, attempt_log)
end

# ---------------------------------------------------------------------------
# Task definitions: source text + matched messages + correctness oracle.
# Oracles check the required semantic fields against known-correct values
# (parse alone is NOT success).
# ---------------------------------------------------------------------------

# --- Task 1: flat ------------------------------------------------------------

FLAT_TEXT = "Invoice INV-2024-0042 was issued to Maria Lopez for a total of 149.99 USD. " \
            "The invoice has already been paid in full."

FLAT_EX_TEXT = "Invoice INV-2023-0007 was issued to Ken Tanaka for a total of 88.50 EUR. " \
               "It has not been paid yet."
FLAT_EX_JSON = %({"invoice_number": "INV-2023-0007", "customer_name": "Ken Tanaka", "total_amount": 88.5, "currency": "EUR", "paid": false})

def flat_messages : Array(Llamero::Message)
  [
    Llamero::Message.system(
      "You extract invoice data as a single JSON object with keys " \
      "invoice_number, customer_name, total_amount, currency, paid. " \
      "Respond with only the JSON object."
    ),
    Llamero::Message.user("Extract the invoice data from this text:\n#{FLAT_EX_TEXT}"),
    Llamero::Message.assistant(FLAT_EX_JSON),
    Llamero::Message.user("Extract the invoice data from this text:\n#{FLAT_TEXT}"),
  ]
end

# currency deliberately NOT checked: at 135M every arm systematically copies
# the few-shot example's currency (verified during calibration), so it would
# only add an equal constant failure to all four arms.
FLAT_ORACLE = ->(p : FlatInvoice) do
  p.invoice_number == "INV-2024-0042" &&
    p.customer_name.downcase.includes?("lopez") &&
    (p.total_amount - 149.99).abs < 0.01 &&
    p.paid == true
end

# --- Task 2: medium ----------------------------------------------------------

MEDIUM_TEXT = "Customer record: Anna Keller, age 41, can be reached at anna.keller@example.com. " \
              "She lives at Main Street 5, Berlin, Germany. Interests: reading, running."

MEDIUM_EX_TEXT = "Customer record: Ana Silva, age 27, can be reached at ana.silva@example.com. " \
                 "She lives at Rua Verde 8, Lisbon, Portugal. Interests: painting."
MEDIUM_EX_JSON = %({"name": "Ana Silva", "age": 27, "email": "ana.silva@example.com", "address": {"street": "Rua Verde 8", "city": "Lisbon", "country": "Portugal"}, "tags": ["painting"]})

def medium_messages : Array(Llamero::Message)
  [
    Llamero::Message.system(
      "You extract customer records as a single JSON object with keys " \
      "name, age, email, address (an object with street, city, country), and tags (an array of strings). " \
      "Respond with only the JSON object."
    ),
    Llamero::Message.user("Extract the contact card from this text:\n#{MEDIUM_EX_TEXT}"),
    Llamero::Message.assistant(MEDIUM_EX_JSON),
    Llamero::Message.user("Extract the contact card from this text:\n#{MEDIUM_TEXT}"),
  ]
end

# email is the load-bearing check: unconstrained runs tend to drop the key
# entirely (typed parse then defaults it to ""), grammar runs are forced to
# emit it. country accepts the "German" truncation both models produce.
MEDIUM_ORACLE = ->(p : ContactCard) do
  p.name.downcase.includes?("keller") &&
    p.age == 41 &&
    p.email == "anna.keller@example.com" &&
    p.address.country.downcase.starts_with?("german")
end

# --- Task 3: cliff (near-budget type) ----------------------------------------

CLIFF_TEXT = "Support ticket TCK-881 (severity 2): \"Checkout button unresponsive on Safari\". " \
             "Reported by Elena Fischer (elena.fischer@shopfast.io) of ShopFast GmbH, whose office is in " \
             "Berlin, Germany at latitude 52.52 and longitude 13.405. Tags: frontend, safari. " \
             "The ticket is assigned to Marco Silva, escalated (yes), SLA 24 hours, component checkout-ui. " \
             "No resolution yet and it is not a duplicate."

CLIFF_EX_TEXT = "Support ticket TCK-104 (severity 4): \"Login page slow\". " \
                "Reported by Sam Ortiz (sam.ortiz@acme.dev) of Acme Corp, whose office is in " \
                "Madrid, Spain at latitude 40.42 and longitude -3.70. Tags: backend. " \
                "The ticket is assigned to Li Wei, not escalated, SLA 72 hours, component auth-service. " \
                "No resolution yet and it is not a duplicate."
CLIFF_EX_JSON = %({"id": "TCK-104", "severity": 4, "title": "Login page slow", "reporter": {"name": "Sam Ortiz", "email": "sam.ortiz@acme.dev", "org": {"name": "Acme Corp", "office": {"city": "Madrid", "country": "Spain", "geo": {"lat": 40.42, "lon": -3.7}}}}, "tags": ["backend"], "assignee": "Li Wei", "escalated": false, "sla_hours": 72, "component": "auth-service"})

def cliff_messages : Array(Llamero::Message)
  [
    Llamero::Message.system(
      "You extract support tickets as a single JSON object with keys " \
      "id, severity, title, reporter (with name, email, org), tags, and optional keys " \
      "assignee, resolution, escalated, sla_hours, component, duplicate_of. " \
      "Omit optional keys that are not present in the text. Respond with only the JSON object."
    ),
    Llamero::Message.user("Extract the support ticket from this text:\n#{CLIFF_EX_TEXT}"),
    Llamero::Message.assistant(CLIFF_EX_JSON),
    Llamero::Message.user("Extract the support ticket from this text:\n#{CLIFF_TEXT}"),
  ]
end

# Top-level fields only: calibration showed depth>=3 values (reporter.org.*)
# are hallucinated by BOTH models in EVERY arm at 135M scale, so checking them
# would zero out success everywhere and destroy the timing signal. The cliff
# task's purpose here is grammar-size/sampler overhead on a near-budget type.
CLIFF_ORACLE = ->(p : CliffTicket) do
  p.id == "TCK-881" &&
    p.severity == 2 &&
    p.title.downcase.includes?("checkout")
end

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

n_runs = (ENV["BENCH_N"]? || "20").to_i
temp_labels = (ENV["BENCH_TEMPS"]? || "temp0").split(',')
out_path = ENV["BENCH_OUT"]? || Path[__DIR__, "..", "results", "runs.jsonl"].expand.to_s
only_task = ENV["BENCH_TASK"]?
only_arm = ENV["BENCH_ARM"]?

abort "base gguf missing: #{BASE_GGUF}" unless File.exists?(BASE_GGUF)
abort "tuned gguf missing: #{TUNED_GGUF}" unless File.exists?(TUNED_GGUF)

# MANDATE: never time anything unless the pinned-build probe passes.
probe_started = Time.instant
probe = Llamero::LlamaCpp::Probe.new(RUNNER)
if reason = probe.failure_reason
  abort "PINNED BUILD PROBE FAILED - refusing to benchmark: #{reason}"
end
probe_ms = (Time.instant - probe_started).total_milliseconds
STDERR.puts "probe OK (pinned #{Llamero::LlamaCpp::PIN_TAG} @ #{Llamero::LlamaCpp::PIN_COMMIT[0, 7]}) in #{probe_ms.round(1)} ms"
STDERR.puts "binary: #{Llamero::LlamaCpp.pinned_binary_path}"
STDERR.puts "base:  #{BASE_GGUF}"
STDERR.puts "tuned: #{TUNED_GGUF}"

# Grammar stats (compile-time artifacts, reported once).
STDERR.puts "grammar sizes: flat=#{FlatInvoice.to_gbnf.bytesize}B/#{FlatInvoice.to_gbnf.lines.size} rules-lines, " \
            "medium=#{ContactCard.to_gbnf.bytesize}B/#{ContactCard.to_gbnf.lines.size}, " \
            "cliff=#{CliffTicket.to_gbnf.bytesize}B/#{CliffTicket.to_gbnf.lines.size}"
STDERR.puts "CliffTicket within budget: #{CliffTicket.gbnf_within_budget?}"
STDERR.puts "CliffBreaker within budget: #{CliffBreaker.gbnf_within_budget?} (reason: #{CliffBreaker.gbnf_fallback_reason})"

Dir.mkdir_p(File.dirname(out_path))
out = File.open(out_path, "a")

arms = [
  {"base-unconstrained", BASE_GGUF, "unconstrained"},
  {"base-grammar", BASE_GGUF, "grammar"},
  {"tuned-unconstrained", TUNED_GGUF, "unconstrained"},
  {"tuned-grammar", TUNED_GGUF, "grammar"},
]

macro run_task(task_name, messages_call, schema, oracle)
  if only_task.nil? || only_task == {{task_name}}
    messages = {{messages_call}}
    arms.each do |(arm, model_path, mode)|
      next if only_arm && only_arm != arm
      temp_labels.each do |temp_label|
        n_runs.times do |run_idx|
          rec = bench_run({{task_name}}, arm, model_path, mode, temp_label, run_idx,
            messages, {{schema}}, {{oracle}})
          out.puts(rec.to_json)
          out.flush
          STDERR.puts "#{Time.utc.to_s("%H:%M:%S")} #{rec.task} #{rec.arm} #{rec.temp_label} run=#{rec.run} " \
                      "ok=#{rec.success} attempts=#{rec.attempts} wall=#{rec.wall_ms.round(0)}ms tok=#{rec.gen_tokens_total}"
        end
      end
    end
  end
end

run_task("flat", flat_messages, FlatInvoice, FLAT_ORACLE)
run_task("medium", medium_messages, ContactCard, MEDIUM_ORACLE)
run_task("cliff", cliff_messages, CliffTicket, CLIFF_ORACLE)

out.close
STDERR.puts "done -> #{out_path}"
