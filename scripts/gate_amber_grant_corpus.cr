require "../src/native/amber_compile_judge"
require "json"
require "option_parser"
require "set"

class AmberCorpusPair
  include JSON::Serializable

  property kind : String = ""
  property prompt : String = ""
  property completion : String = ""
end

class AmberCorpusProvenance
  include JSON::Serializable

  property topic : String = ""
  property prompt : String = ""
  property completion : String = ""
  property source_symbol : String = ""
  property source_file : String = ""
end

ROOT                = Path[__DIR__].parent
DATA                = ROOT.join("training_data", "amber")
GRANT_ROOT          = ROOT.join(".crystal-cache", "grant-c6b5e72")
AMBER_ROOT          = ROOT.join(".crystal-cache", "amber-f2a1490")
MULTI_TENANCY_GUIDE = ROOT.join(".crystal-cache", "guide-fd988199", "docs", "v2", "guides", "models", "grant", "multi-tenancy.md")
EXPECTED_TOPICS     = {
  "row_tenancy"         => 14,
  "schema_tenancy"      => 14,
  "amber_tenant_pipe"   => 14,
  "apartment_migration" => 14,
  "raw_sql"             => 20,
  "parity"              => 8,
}
BRITISH_ENGLISH = Regex.new(
  "\\b(colour|colours|behaviour|behaviours|centre|centres|grey|analyse|analysed|analysing|optimise|optimised|licence|catalogue|cancelled|organise|organisation)\\b",
  Regex::Options::IGNORE_CASE
)
CODE_DEFINITION = /\b(class|module|struct|enum|def|record)\b/
WARNING_LINE    = Regex.new("(?i)\\bwarning:")

pair_path = DATA.join("grant_tenancy_rawsql_pairs.jsonl")
provenance_path = DATA.join("grant_tenancy_rawsql_provenance.jsonl")
baseline_path = DATA.join("amber_v2_sft.jsonl")
self_check = false
rows_only = false

parser = OptionParser.new do |options|
  options.banner = "Usage: crystal-alpha run scripts/gate_amber_grant_corpus.cr -- [options]"
  options.on("--pairs PATH", "pair JSONL to check") { |value| pair_path = Path[value] }
  options.on("--provenance PATH", "provenance JSONL to check") { |value| provenance_path = Path[value] }
  options.on("--baseline PATH", "existing SFT JSONL used for dedupe") { |value| baseline_path = Path[value] }
  options.on("--self-check", "prove the source matcher and compiler reject invalid probes") { self_check = true }
  options.on("--rows-only", "print and measure three verbatim rows per topic") { rows_only = true }
  options.on("-h", "--help", "show this help") { puts options; exit }
end
parser.parse

def word_boundary_match?(text : String, symbol : String) : Bool
  pattern = Regex.new("\\b" + Regex.escape(symbol) + "\\b", Regex::Options::IGNORE_CASE)
  pattern.matches?(text)
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
  shared_size = (left_tokens & right_tokens).size
  union_size = (left_tokens | right_tokens).size
  return 0.0 if union_size == 0
  shared_size.to_f / union_size
end

def read_pairs(path : Path) : Array(AmberCorpusPair)
  rows = [] of AmberCorpusPair
  File.each_line(path.to_s) do |line|
    next if line.blank?
    rows << AmberCorpusPair.from_json(line)
  end
  rows
end

def read_provenance(path : Path) : Array(AmberCorpusProvenance)
  rows = [] of AmberCorpusProvenance
  File.each_line(path.to_s) do |line|
    next if line.blank?
    rows << AmberCorpusProvenance.from_json(line)
  end
  rows
end

list_of_errors = [] of String
format_path = ROOT.join(".crystal-cache", "amber-grant-pairs-format.cr")
judge = Llamero::Native::AmberCompileJudge.new(
  amber_root: AMBER_ROOT.to_s,
  grant_root: GRANT_ROOT.to_s,
  work_dir: ROOT.join(".crystal-cache", "amber-grant-compile-judge")
)

unless judge.available?
  abort "Amber compile judge unavailable at #{AMBER_ROOT}"
end

if self_check
  source_matcher_rejected = !word_boundary_match?("Grant::Tenant.with(id) do end", "Tenant.wrong")
  missing_call = "Grant::Tenant.this_method_does_not_exist_for_the_corpus_gate"
  compiler_rejected = !judge.compile?(missing_call)
  puts "source-symbol negative probe: #{source_matcher_rejected ? "REJECTED as expected" : "FALSE PASS"}"
  puts "compiler negative probe: #{compiler_rejected ? "REJECTED as expected" : "FALSE PASS"}"
  puts judge.last_output unless compiler_rejected || judge.last_output.empty?
  abort "corpus gate self-check failed" unless source_matcher_rejected && compiler_rejected
  exit
end

pairs = read_pairs(pair_path)
provenance = read_provenance(provenance_path)
baseline = read_pairs(baseline_path)

formatted_source = String.build do |source|
  pairs.each_with_index do |pair, index|
    source << pair.completion
    source << "\n\n" unless index == pairs.size - 1
  end
  source << "\n"
end
File.write(format_path.to_s, formatted_source)
format_output = IO::Memory.new
format_status = Process.run(
  "crystal-alpha",
  ["tool", "format", "--check", format_path.to_s],
  output: format_output,
  error: format_output
)
format_ok = format_status.success?
list_of_errors << "Crystal formatter check failed: #{format_output}" unless format_ok

list_of_errors << "expected exactly 84 new pairs, found #{pairs.size}" unless pairs.size == 84
list_of_errors << "expected exactly 84 provenance rows, found #{provenance.size}" unless provenance.size == 84
list_of_errors << "expected the original 212-row baseline, found #{baseline.size}" unless baseline.size == 212
list_of_errors << "pair/provenance row counts differ" unless pairs.size == provenance.size

topic_counts = Hash(String, Int32).new(0)
seen_new_prompts = Set(String).new
definition_count = 0
british_matches = [] of String
compiled_count = 0
compiler_warning_count = 0
source_guide_path = MULTI_TENANCY_GUIDE.expand.to_s
grant_prefix = GRANT_ROOT.expand.to_s + "/"

puts "=== Read-the-rows check: three verbatim pairs per topic ==="
verbatim_rows_printed = 0
EXPECTED_TOPICS.keys.each do |topic|
  topic_indices = [] of Int32
  provenance.each_with_index do |source, index|
    topic_indices << index if source.topic == topic
  end
  puts "\n--- #{topic} (#{topic_indices.size} total) ---"
  topic_rows_printed = 0
  topic_indices.each do |index|
    if topic_rows_printed < 3
      puts "PAIR #{index + 1} PROMPT:\n#{pairs[index].prompt}"
      puts "PAIR #{index + 1} COMPLETION (verbatim):\n#{pairs[index].completion}"
      topic_rows_printed += 1
      verbatim_rows_printed += 1
    end
  end
  list_of_errors << "read-the-rows check: topic #{topic} printed fewer than three pairs" if topic_rows_printed != 3
end
if rows_only
  puts "read-the-rows: #{verbatim_rows_printed}/#{EXPECTED_TOPICS.size * 3} verbatim pair rows printed"
  abort list_of_errors.join("\n") unless list_of_errors.empty?
  exit
end

pairs.each_with_index do |pair, index|
  row_number = index + 1
  source = provenance[index]?
  list_of_errors << "pair #{row_number}: kind must be pair" unless pair.kind == "pair"
  list_of_errors << "pair #{row_number}: prompt is blank" if pair.prompt.blank?
  list_of_errors << "pair #{row_number}: completion is blank" if pair.completion.blank?
  definition_count += 1 if CODE_DEFINITION.matches?(pair.completion)
  if match = BRITISH_ENGLISH.match(pair.prompt + "\n" + pair.completion)
    british_matches << "pair #{row_number}: #{match[1]}"
  end

  prompt_key = normalized_prompt(pair.prompt)
  if seen_new_prompts.includes?(prompt_key)
    list_of_errors << "pair #{row_number}: duplicate normalized prompt"
  else
    seen_new_prompts << prompt_key
  end

  if source
    topic_counts[source.topic] += 1
    if pair.prompt != source.prompt || pair.completion != source.completion
      list_of_errors << "pair #{row_number}: pair and provenance content differ"
    end
    if source.topic.blank? || source.source_symbol.blank? || source.source_file.blank?
      list_of_errors << "pair #{row_number}: provenance topic/source_symbol/source_file is required"
    end

    source_path = Path[source.source_file].expand
    source_path_string = source_path.to_s
    is_allowed_source = source_path_string.starts_with?(grant_prefix) || source_path_string == source_guide_path
    if !is_allowed_source || !File.file?(source_path_string)
      list_of_errors << "pair #{row_number}: source_file is outside the allowed Grant source/guides: #{source.source_file}"
    else
      source_text = File.read(source_path_string)
      unless word_boundary_match?(source_text, source.source_symbol)
        list_of_errors << "pair #{row_number}: source_symbol is not word-boundary grounded: #{source.source_symbol}"
      end
    end

    unless word_boundary_match?(pair.completion, source.source_symbol)
      list_of_errors << "pair #{row_number}: completion does not use cited symbol #{source.source_symbol}"
    end
  end

  unless judge.compile?(pair.completion)
    list_of_errors << "pair #{row_number}: COMPILE failed (#{source.try(&.topic) || "no topic"})"
    puts "\nCOMPILER OUTPUT FOR PAIR #{row_number}:\n#{judge.last_output}"
  else
    compiled_count += 1
    compiler_warning_count += judge.last_output.scan(WARNING_LINE).size
  end
end

EXPECTED_TOPICS.each do |topic, expected_count|
  actual_count = topic_counts[topic]
  list_of_errors << "topic #{topic}: expected #{expected_count} pairs, found #{actual_count}" unless actual_count == expected_count
end
topic_counts.each_key do |topic|
  list_of_errors << "unexpected topic #{topic}" unless EXPECTED_TOPICS.has_key?(topic)
end

baseline_prompts = Set(String).new
baseline.each { |pair| baseline_prompts << normalized_prompt(pair.prompt) }
pairs.each_with_index do |pair, index|
  list_of_errors << "pair #{index + 1}: duplicate of existing SFT prompt" if baseline_prompts.includes?(normalized_prompt(pair.prompt))
  pairs.each_with_index do |other, other_index|
    next if other_index <= index
    if token_jaccard(pair.prompt, other.prompt) >= 0.8
      list_of_errors << "pairs #{index + 1} and #{other_index + 1}: near-duplicate prompts"
    end
  end
  baseline.each_with_index do |old_pair, old_index|
    if token_jaccard(pair.prompt, old_pair.prompt) >= 0.8
      list_of_errors << "pair #{index + 1}: near-duplicate of baseline prompt #{old_index + 1}"
    end
  end
end

unless british_matches.empty?
  list_of_errors.concat(british_matches.map { |match| "American English word-boundary check: #{match}" })
end

definition_percent = pairs.empty? ? 0.0 : (definition_count * 100.0 / pairs.size)
compile_color = if compiled_count != pairs.size
                  "RED"
                elsif compiler_warning_count > 0
                  "YELLOW"
                else
                  "GREEN"
                end

puts "\n=== Deterministic corpus gate ==="
puts "pair/provenance alignment: #{pairs.size}/#{pairs.size}"
puts "grounded source symbols: #{pairs.size - list_of_errors.count(&.includes?("source_symbol"))}/#{pairs.size} (word-boundary check in cited file)"
puts "completion symbol coverage: #{pairs.size - list_of_errors.count(&.includes?("completion does not use cited symbol"))}/#{pairs.size}"
puts "Crystal formatter passed: #{format_ok}"
puts "code definitions in completions: #{definition_count}/#{pairs.size} (#{definition_percent.round(1)}%)"
puts "compile: #{compiled_count}/#{pairs.size}; warnings=#{compiler_warning_count}; traffic light=#{compile_color}"
puts "baseline: #{baseline.size} rows; normalized duplicate count and near-duplicate checks complete"
puts "American English: #{british_matches.size} word-boundary matches"
puts "read-the-rows: #{verbatim_rows_printed}/#{EXPECTED_TOPICS.size * 3} verbatim pair rows printed"
puts "topic counts: #{EXPECTED_TOPICS.keys.map { |topic| "#{topic}=#{topic_counts[topic]}" }.join(", ")}"

unless list_of_errors.empty?
  puts "\nFAILURES (#{list_of_errors.size}):"
  list_of_errors.each { |error| puts "- #{error}" }
  exit 1
end

puts "\nPASS: all 84 new pairs are grounded, deduped, idiomatic-symbol complete, and compile against Grant/Amber."
