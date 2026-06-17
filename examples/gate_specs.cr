# Gate worker-written specs with SpecRunner.meaningful? (Codex's mutation-test
# gate): keep only specs that PASS the correct impl AND kill >=1 behavior mutant.
# Writes the verified impl->spec training pairs.
#
#   crystal run examples/gate_specs.cr
require "../src/llamero"
require "json"

SR = Llamero::Native::SpecRunner
indir = "/tmp/crystal_specs"
dir = Path[__DIR__].parent.join("training_data", "crystal")
kept = [] of NamedTuple(impl: String, spec: String, category: String)
per = Hash(String, Tuple(Int32, Int32)).new({0, 0})
total = 0
Dir.glob(File.join(indir, "*.jsonl")).sort.each do |f|
  cat = File.basename(f, ".jsonl")
  raw = 0; keep = 0
  File.each_line(f) do |line|
    next if line.strip.empty?
    d = JSON.parse(line) rescue next
    impl = d["impl"]?.try(&.as_s?) || ""
    spec = d["spec"]?.try(&.as_s?) || ""
    next if impl.blank? || spec.blank?
    raw += 1
    total += 1
    STDERR.print "\r  gating #{total}... kept #{kept.size}"
    if SR.meaningful?(impl, spec)
      kept << {impl: impl, spec: spec, category: cat}
      keep += 1
    end
  end
  per[cat] = {raw, keep}
end
STDERR.puts

File.open(dir.join("spec_pairs.jsonl").to_s, "w") do |io|
  kept.each do |k|
    prompt = "Write a crystal spec for the following code. Use describe/it with concrete assertions and cover edge cases.\n\n#{k[:impl]}"
    io.puts({kind: "pair", prompt: prompt, completion: k[:spec], category: "spec:#{k[:category]}"}.to_json)
  end
end
puts "=== spec meaningfulness gate (passes impl AND kills a behavior mutant) ==="
per.each { |c, (r, k)| puts "  #{c.ljust(18)} #{k}/#{r} meaningful" }
puts "kept #{kept.size} -> training_data/crystal/spec_pairs.jsonl"
