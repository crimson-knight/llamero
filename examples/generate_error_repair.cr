# Generate compiler-error-repair training pairs from the known-good directive
# corpus: mutate each program, capture the REAL crystal error, emit
# (broken + error) -> fixed. Self-labeling + deterministically gradable.
#
#   crystal run examples/generate_error_repair.cr
require "../src/llamero"
require "json"

ER = Llamero::Native::ErrorRepair
dir = Path[__DIR__].parent.join("training_data", "crystal")
src = dir.join("directive_pairs.jsonl")
abort "need directive_pairs.jsonl" unless File.exists?(src)

programs = [] of String
File.each_line(src.to_s) do |l|
  next if l.strip.empty?
  c = JSON.parse(l)["completion"]?.try(&.as_s?)
  programs << c if c && !c.blank?
end
puts "known-good programs: #{programs.size}"

raw = [] of Llamero::Native::ErrorRepair::RepairPair
programs.each_with_index do |code, i|
  ER.from_program(code).each { |p| raw << p }
  STDERR.print "\r  mutated #{i + 1}/#{programs.size} -> #{raw.size} repair pairs" if (i % 5).zero?
end
STDERR.puts

# Balance the distribution (Codex: syntax must not dominate). Hard-cap the
# syntax family (drop-end) to a minority vs the semantic families, and dedup.
nonsyntax = raw.count { |p| p.mutation != "drop-end" }
drop_end_cap = Math.max(3, nonsyntax // 2)   # syntax stays <= ~33% of total
seen = Set(String).new
by_mut = Hash(String, Int32).new(0)
pairs = raw.select do |p|
  next false unless seen.add?("#{p.mutation}:#{p.error[0, 80]}:#{p.fixed[0, 60]}")
  next false if p.mutation == "drop-end" && by_mut["drop-end"] >= drop_end_cap
  by_mut[p.mutation] += 1
  true
end

File.open(dir.join("error_repair_pairs.jsonl").to_s, "w") do |io|
  pairs.each do |p|
    prompt, completion = ER.to_training_pair(p)
    io.puts({kind: "pair", prompt: prompt, completion: completion, category: "error-repair", mutation: p.mutation}.to_json)
  end
end
puts "wrote #{pairs.size} error-repair pairs -> training_data/crystal/error_repair_pairs.jsonl"
puts "by mutation: #{by_mut}"
puts "--- sample ---"
if s = pairs.first?
  pr, _ = ER.to_training_pair(s)
  puts pr[0, 400]
end
