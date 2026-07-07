require "llamero"
require "json"
require "./schemas"

# Cliff characterization per the benchmark protocol:
#   1. grammar-size scaling across the graded types (within budget)
#   2. what happens PAST the budget: refusal reason, :auto fallback engaging
#      (with the one-time runtime warn), end-to-end timing of the fallback
#   3. forced :grammar past the budget is a COMPILE-TIME refusal -> proven by
#      a shell-out in run_cliff_compile_refusal.sh, not here.

BASE_GGUF = Path[__DIR__, "..", "models", "smollm-135m-base-f16.gguf"].expand.to_s

puts "== 1. grammar size scaling (within budget) =="
{ {"FlatInvoice", FlatInvoice.to_gbnf}, {"ContactCard", ContactCard.to_gbnf}, {"CliffTicket", CliffTicket.to_gbnf} }.each do |(name, g)|
  root_line = g.lines.find { |l| l.starts_with?("root") } || ""
  alt_count = root_line.count('|') + 1
  puts "#{name}: #{g.bytesize} bytes, #{g.lines.size} lines, root alternatives: #{alt_count}"
end

puts
puts "== 2. past the budget: CliffBreaker (7 optionals, cap 6) =="
puts "to_gbnf? -> #{CliffBreaker.to_gbnf?.inspect}"
puts "gbnf_within_budget? -> #{CliffBreaker.gbnf_within_budget?}"
puts "gbnf_fallback_reason -> #{CliffBreaker.gbnf_fallback_reason.inspect}"

puts
puts "== 3. :auto fallback engaging end-to-end (schema-prompt path) =="
backend = Llamero::LlamaCpp::CompletionBackend.new(
  model_path: BASE_GGUF,
  grammar_parse_retries: 0,
  context_size: 2048,
  threads: 4,
  timeout: 3.minutes
)

messages = [
  Llamero::Message.system(
    "You extract support tickets as a single JSON object. Respond with only the JSON object."
  ),
  Llamero::Message.user(
    "Extract the support ticket from this text:\n" \
    "Support ticket TCK-881 (severity 2): \"Checkout button unresponsive on Safari\"."
  ),
]

started = Time.instant
begin
  resp = backend.chat_structured(messages, CliffBreaker, generation_mode: :auto, temperature: 0.0_f32, max_tokens: 400)
  wall = (Time.instant - started).total_milliseconds
  puts "constraint_backend: #{resp.constraint_backend}"
  puts "wall: #{wall.round(0)} ms"
  puts "content[0,120]: #{resp.content[0, 120].inspect}"
  puts "parsed: #{resp.parsed ? "non-nil" : "nil"}"
rescue ex : Llamero::Native::StructuredParseError
  wall = (Time.instant - started).total_milliseconds
  puts "StructuredParseError after #{wall.round(0)} ms (schema-prompt path CAN fail invalid - that is the point)"
  puts "  generation_mode=#{ex.generation_mode.inspect} constraint_backend=#{ex.constraint_backend.inspect} fallback_reason=#{ex.fallback_reason.inspect}"
  puts "  raw[0,160]: #{ex.raw_text[0, 160].inspect}"
end
