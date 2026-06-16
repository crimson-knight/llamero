# Unsupervised continued-pretraining proof: teach a small Gemma the llamero
# domain from raw structured documentation (no prompt/completion pairs, no chat
# template) — the first layer of a multi-method training pipeline.
#
#   crystal run examples/train_unsupervised_docs_adapter.cr
#   crystal run examples/train_unsupervised_docs_adapter.cr -- mlx-community/gemma-3-1b-it-4bit
#
# TrainingDataset.from_documents chunks the corpus and trains each chunk verbatim
# with full-sequence causal-LM loss, so the model absorbs the docs. Success = the
# training loss falls sharply (the model learns to predict the documentation).
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"
CORPUS = Path[__DIR__].parent.join("training_data", "llamero_concepts_corpus.txt")

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found (build: cd native/llamero-mlx && ./build.sh)" unless bridge

runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model

dataset = Llamero::Native::TrainingDataset.from_documents([CORPUS.to_s])
puts "unsupervised corpus: #{dataset.size} chunks, raw_text?=#{dataset.raw_text?}, template=#{dataset.template_source}"

config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = (ENV["ITERS"]?.try(&.to_i?) || 200)
config.num_layers = 8
config.batch_size = 1
config.learning_rate = 1e-4
config.steps_per_report = 20

losses = [] of Float64
puts "continued-pretraining 'llamero-concepts-pretrain' (#{config.iterations} iters)..."
session.train_adapter("llamero-concepts-pretrain", dataset, config) do |p|
  losses << p.loss
  puts "  iter #{p.iteration}/#{p.total_iterations} loss=#{p.loss.round(3)} (#{p.tokens_per_second.round(0)} tok/s)"
end

# Show the model writing llamero-flavored text with the new knowledge active.
session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("llamero-concepts-pretrain")]),
  fuse: true
)
sample = session.chat([Llamero::Message.user("In one sentence, what is Llamero::Native::ModelSession?")], max_tokens: 80)
runtime.close

first = losses.first
last = losses.last
lo = losses.min
puts "\nloss: first=#{first.round(3)} min=#{lo.round(3)} last=#{last.round(3)}"
puts "sample (adapter active): #{sample.content.strip[0, 200]}"
if last < first
  puts "UNSUPERVISED PRETRAIN OK — loss fell #{((1 - last / first) * 100).round(0)}% (#{first.round(2)} -> #{last.round(2)})"
else
  abort "UNSUPERVISED PRETRAIN FAILED — loss did not fall (#{first.round(2)} -> #{last.round(2)})"
end
