# Phase 1 of the training toolchain: turn documentation into training data,
# deterministically and valid-by-construction (no model, no hallucinated code).
#
#   crystal run examples/generate_training_from_docs.cr
#
# Two sources:
#   1. DocExtractor — pull the authored code examples out of a markdown guide
#      (or `crystal docs --format=json` API docs) with their context.
#   2. ExampleGenerator — mix and match documented chunks into the full breadth
#      of VALID controller variations, then compile-verify them.
require "../src/llamero"

DOCS_DIR = Path[__DIR__].parent.join("training_data", "docs")
GUIDE = DOCS_DIR.join("amber_controller_guide.md")

# ---- 1. Extract authored examples from the guide ----
extractor = Llamero::Native::DocExtractor.from_markdown([GUIDE.to_s])
pairs_path = DOCS_DIR.join("amber_controller_pairs.jsonl")
n = extractor.write_corpus_jsonl(pairs_path, kind: :pair)
puts "extracted #{n} authored examples from #{GUIDE.basename} -> #{pairs_path.basename}"
puts "  sample context: #{extractor.crystal_examples.first.context[0, 90]}..."

# ---- 2. Generate the breadth of VALID controller variations ----
# A grammar of composable chunks: resource name x optional filter x a subset of
# actions. Every combination is a valid controller by construction.
ACTIONS = [
  %(def index\n    render("index")\n  end),
  %(def show\n    render("show", id: params[:id])\n  end),
  %(def destroy\n    redirect_to("/")\n  end),
]

gen = Llamero::Native::ExampleGenerator.new(<<-TEMPLATE)
class {{resource}}Controller < ApplicationController
  {{filter}}{{actions}}
end
TEMPLATE
gen.slot("resource", ["Articles", "Users"])
gen.slot("filter", ["", "before_action :require_login\n\n  "])
gen.combo("actions", ACTIONS, min: 1, join: "\n\n  ")

all = gen.to_a
puts "\ngenerated #{all.size} controller variations from #{ACTIONS.size} action chunks"

# Compile-verify each against a minimal Amber-shaped stub (stands in for the real
# framework). Valid-by-construction means we expect 100% to pass.
stub = <<-STUB
abstract class ApplicationController
  def params; {} of Symbol => String; end
  def render(*args, **opts); end
  def redirect_to(path); end
  macro before_action(*args); end
end
STUB
verified = gen.verified { |controller| "#{stub}\n#{controller}" }
puts "compile-verified: #{verified.size}/#{all.size} valid"

gen_path = DOCS_DIR.join("amber_generated_corpus.jsonl")
File.open(gen_path.to_s, "w") do |f|
  verified.each { |code| f.puts({kind: "pair", prompt: "Write a valid Amber controller.", completion: code}.to_json) }
end
puts "wrote #{verified.size} verified variations -> #{gen_path.basename}"

if verified.size == all.size && n > 0
  puts "\nDOC->DATA OK: #{n} extracted + #{verified.size} generated, all valid"
else
  abort "DOC->DATA INCOMPLETE (extracted=#{n} verified=#{verified.size}/#{all.size})"
end
