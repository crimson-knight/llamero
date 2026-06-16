# Phase A (deterministic core): extract a real Amber v2 training corpus from the
# local Amber docs (gitbook markdown) and framework source doc-comments, using
# the shipped DocExtractor. These are AUTHORED examples — valid by authorship, no
# compile-verify needed. Produces kind-tagged JSONL the multi-method pipeline
# consumes.
#
#   crystal run examples/extract_amber_corpus.cr
require "../src/llamero"
require "file_utils"

AMBER_DOCS = ENV["AMBER_DOCS"]? || "/Users/crimsonknight/open_source_coding_projects/amber_docs"
AMBER_SRC  = ENV["AMBER_SRC"]? || "/Users/crimsonknight/open_source_coding_projects/amber/src"
OUT        = Path[__DIR__].parent.join("training_data", "amber")

# 1. The gitbook docs (cookbook + guides): usage-oriented code with prose context.
md_files = Dir.glob(File.join(AMBER_DOCS, "**", "*.md")).reject { |f| f.includes?("/.git/") }
abort "no Amber docs at #{AMBER_DOCS}" if md_files.empty?
docs = Llamero::Native::DocExtractor.from_markdown(md_files)

# 2. The framework source doc-comments (the DSLs and APIs themselves), pulled
#    straight from the .cr files' markdown doc blocks (no `crystal docs` build
#    needed — ingest each file's leading doc comments as markdown is overkill, so
#    we treat the docs as the primary source and note source as a future add).

FileUtils.mkdir_p(OUT.to_s)
pairs = docs.write_corpus_jsonl(OUT.join("amber_pairs.jsonl"), kind: :pair)
text = docs.write_corpus_jsonl(OUT.join("amber_text.jsonl"), kind: :text)

by_lang = Hash(String, Int32).new(0)
docs.examples.each { |e| by_lang[e.language] += 1 }

puts "=== Amber v2 corpus extraction ==="
puts "docs: #{md_files.size} markdown files -> #{docs.examples.size} examples"
puts "by language: #{by_lang.to_a.sort_by { |(_, n)| -n }.first(6).to_h}"
puts "crystal examples: #{docs.crystal_examples.size}"
puts "wrote -> training_data/amber/amber_pairs.jsonl (#{pairs}), amber_text.jsonl (#{text})"
puts "\n=== samples ==="
docs.crystal_examples.first(4).each do |e|
  puts "• #{e.context[0, 80].gsub('\n', ' ')}"
  puts "    #{e.code.lines.first?.try(&.strip)}"
end
