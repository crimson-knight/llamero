# llamero — agent quick reference

llamero is a Crystal library for AI applications: cloud provider clients
(OpenAI, Anthropic, Groq, OpenRouter) with failover, plus native local
inference and LoRA/QLoRA adapter training on Apple Silicon via MLX. One
require: `require "llamero"`.

This file is the condensed API contract. Fuller task recipes live in the
shipped skills: `cloud-providers`, `local-inference`, `adapter-training`
(installed as `.claude/skills/llamero--<name>/` in consuming projects).

## Cloud chat with failover

```crystal
require "llamero"

class MyAIClient < Llamero::Client # abstract base - MUST subclass
  def initialize
    super(primary: :openai, fallbacks: [:anthropic, :groq])
  end
end

client = MyAIClient.new
response = client.chat([Llamero::Message.user("Hello!")])
puts response.content
```

Keys via env vars: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GROQ_API_KEY`,
`OPENROUTER_API_KEY`. Streaming: `client.chat_stream(messages) { |chunk| print chunk }`.
Direct clients without failover: `Llamero::OpenAIClient.new`,
`Llamero::AnthropicClient.new`, `Llamero::GroqClient.new`,
`Llamero::OpenRouterClient.new`.

## Structured JSON output (cloud and local, same pattern)

```crystal
class PersonInfo < Llamero::BaseGrammar
  property name : String = ""   # every property needs a default
  property age : Int32 = 0
end

response = client.chat_structured([Llamero::Message.user("Random person")], PersonInfo)
person = response.parsed.not_nil!
```

## Local inference on Apple Silicon (no API key)

One-time machine setup: `cd lib/llamero/native/llamero-mlx && ./build.sh`
(builds the Swift MLX bridge, installs to `~/.llamero/lib/`).

```crystal
runtime = Llamero::Native::MLXRuntime.new(model_id: "mlx-community/gemma-4-e2b-it-4bit")
abort "bridge not built" unless runtime.real_bridge? # false => mock responses

session = runtime.start_session
session.load_model # required before chat; downloads model on first run

puts session.chat([Llamero::Message.user("Hi!")]).content
session.chat_stream([Llamero::Message.user("Story?")]) { |chunk| print chunk }
info = session.chat_structured([Llamero::Message.user("Facts about Paris")], CityInfo).parsed.not_nil!

runtime.close
```

The model loads once and stays resident across all calls. (If you swap in a
Qwen3 model, it emits `<think>...</think>` blocks; strip with
`content.gsub(/<think>.*?<\/think>/m, "").strip`. Gemma models do not.)

## Train and toggle a LoRA/QLoRA adapter

```crystal
dataset = Llamero::Native::TrainingDataset.new(
  system_prompt: "You are an LX-900 expert.",
  format: Llamero::Native::TrainingDataset.template_for(runtime.model_id)
)
dataset.add("What injectors does the LX-900 use?", "BR-7741 injectors at 2,150 PSI.")

config = Llamero::Native::AdapterTrainingConfig.new
config.learning_rate = 1e-4 # memorizes small fact sets; default 1e-5 is conservative
config.iterations = 300

session.train_adapter("lx900-manual", dataset, config) do |p|
  puts "iter #{p.iteration}: loss=#{p.loss}"
end

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("lx900-manual")])
)
# ...model now knows the dataset...
session.deactivate_adapters # knowledge off; base model never reloaded
```

Training on a 4-bit model is automatically QLoRA. Artifacts land in
`~/.llamero/adapters/<name>/` (mlx_lm format) and auto-register. Training
requires a loaded model and no active adapters. Always set the dataset
`format:` via `TrainingDataset.template_for(model_id)` — it picks the
built-in `GEMMA` or `CHATML` (Qwen-style) template to match the model.

A worked example that teaches a model llamero's own API:
`lib/llamero/examples/train_llamero_docs_adapter.cr` with the dataset at
`lib/llamero/training_data/llamero_api_qa.jsonl`.

## Facts that prevent wrong guesses

- Response text is `.content` — there is no `.text` or `.message`.
- Native chat lives on `ModelSession` (from `runtime.start_session`), never on
  the runtime.
- `Llamero::Message.user/system/assistant(...)` are the message constructors.
- Without the built bridge, `Llamero::Native` runs against a deterministic
  mock (so specs work anywhere) — check `runtime.real_bridge?`.
- `mlx-community` model conversions (including Gemma) are generally ungated —
  no token needed. Gated repos (e.g. `google/*` originals) need `HF_TOKEN`.
- v1 bridge: one active adapter at a time, scale 1.0.
- `mlx-community/SmolLM-135M-Instruct-4bit` is for pipeline tests only — its
  output is incoherent; use `mlx-community/gemma-4-e2b-it-4bit` or larger.
