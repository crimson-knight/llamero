require "../src/llamero"
require "json"
DE = Llamero::Native::DocExtractor
dir = Path[__DIR__].parent.join("training_data", "crystal")
Dir.mkdir_p(dir.to_s)

ex = DE.from_docs_json(File.read("/tmp/crystal_stdlib.json"))
seen = Set(String).new
kept = ex.crystal_examples.select do |e|
  real = e.code.split('\n').map(&.strip).reject { |l| l.empty? || l.starts_with?('#') }
  next false if real.size < 1 || e.code.size < 15        # drop trivial / output-only
  seen.add?(e.code[0, 200])                              # dedup
end
puts "kept #{kept.size}/#{ex.crystal_examples.size} stdlib examples after filter+dedup"

File.open(dir.join("stdlib_pairs.jsonl").to_s, "w") do |io|
  kept.each { |e| io.puts({kind: "pair", prompt: e.context, completion: e.code}.to_json) }
end
File.open(dir.join("stdlib_text.jsonl").to_s, "w") do |io|
  kept.each { |e| io.puts({kind: "text", text: e.to_text}.to_json) }
end

# Consolidated SFT corpus = stdlib pairs + the 58 version facts.
vf = dir.join("version_facts.jsonl")
total = kept.size
File.open(dir.join("crystal_sft.jsonl").to_s, "w") do |io|
  kept.each { |e| io.puts({kind: "pair", prompt: e.context, completion: e.code}.to_json) }
  if File.exists?(vf)
    n = 0
    File.each_line(vf.to_s) { |l| (io.puts(l); n += 1) unless l.strip.empty? }
    total += n
    puts "+ #{n} version facts"
  end
end
puts "wrote stdlib_pairs.jsonl (#{kept.size}), stdlib_text.jsonl, crystal_sft.jsonl (#{total})"
