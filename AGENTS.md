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

## Storage root for consuming apps

Default storage is `~/.llamero`. Apps that need app-owned AI data set this at
boot before creating runtimes:

```crystal
Llamero.storage_root = Path.home.join(".scribe")
```

`LLAMERO_HOME=/path/to/root` is the env alternative; programmatic wins. The
root controls `models/`, `adapters/`, bridge `lib/` lookup, and configured
audio model caches under `audio_models/`. FluidAudio 0.15.2 still pins English
Kokoro G2P assets to its own TTS cache; see
`development_docs/storage_configuration.md`.

## Local inference on Apple Silicon (no API key)

One-time machine setup: `cd lib/llamero/native/llamero-mlx && ./build.sh`
(builds the Swift MLX bridge, installs to `$LLAMERO_HOME/lib` or
`~/.llamero/lib/`).

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

To keep **several specialized models resident in parallel** (e.g. a small
dense specialist with a domain adapter plus a general chat model) use
`Llamero::Native::ModelPool` — named members load lazily on first use, the
member's default adapter stack auto-activates, and the app routes by name:

```crystal
pool = Llamero::Native::ModelPool.new
pool.add("specialist",
  model_id: "mlx-community/gemma-3-1b-it-4bit",
  adapters: [{"llamero-docs", Llamero::Storage.adapters_dir.join("llamero-docs").to_s}],
  default_stack: Llamero::Native::AdapterStack.additive([
    Llamero::Native::AdapterSlot.new("llamero-docs"),
  ])
)
pool.add("chat", model_id: "mlx-community/gemma-4-e2b-it-4bit")
puts pool.chat("specialist", [Llamero::Message.user("How do I stream tokens?")]).content
puts pool.chat("chat", [Llamero::Message.user("Hello!")]).content
pool.close # closes every member; pool[name] / pool.total_memory_bytes inspect state
```

## Train and toggle a LoRA/QLoRA adapter

```crystal
dataset = Llamero::Native::TrainingDataset.new(
  system_prompt: "You are an LX-900 expert."
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
`Llamero::Storage.adapters_dir/<name>/` (mlx_lm format) and auto-register. Training
requires a loaded model and no active adapters. Chat templates are
automatic: when the model is downloaded locally, `train_adapter` renders the
dataset through the model's own chat template (the same Jinja template used
at inference), falling back to the built-in `GEMMA`/`CHATML` templates via
`TrainingDataset.template_for(model_id)`. Check `dataset.template_source`
after training to see which was used; pass `format:` only to override.
**Train on a dense base model** (`mlx-community/gemma-3-1b-it-4bit`):
Gemma 4 e-series (e2b/e4b) trains to low loss but the adapter has no
inference effect — a known upstream architecture limitation.

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
