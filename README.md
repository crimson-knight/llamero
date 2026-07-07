# Llamero

A Crystal library for interacting with AI/LLM providers with automatic failover and structured output support.

## Supported Providers

| Provider | Features | Best For |
|----------|----------|----------|
| **OpenAI** | Chat, Structured Output, Streaming, Embeddings, Vision | General purpose, GPT-4o |
| **Anthropic** | Chat, Structured Output, Streaming, Vision | Claude models, long context |
| **Groq** | Chat, Structured Output, Streaming, Vision | Ultra-fast inference |
| **OpenRouter** | All features (model-dependent) | Access to 400+ models |

## Native Apple/MLX Track

Llamero ships an Apple-first native runtime for local inference from Crystal
applications: keep an MLX-backed base model resident on Apple Silicon, stream
chat responses through Crystal, parse structured JSON into Crystal objects, and
hot-swap LoRA adapters without reloading the base model.

```crystal
runtime = Llamero::Native::MLXRuntime.new(
  model_id: "mlx-community/gemma-4-e2b-it-4bit"
)

session = runtime.start_session
session.load_model

session.chat_stream([Llamero::Message.user("Hello!")]) do |chunk|
  print chunk
end

# Hot-swap a LoRA adapter while the base model stays resident
runtime.adapters.register("sql", Path["adapters/sql"])
session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("sql")])
)

# Or train your own adapter on the resident model (QLoRA on 4-bit models),
# from a golden dataset of prompt/completion pairs - no Python required
dataset = Llamero::Native::TrainingDataset.new(system_prompt: "You are an LX-900 expert.")
dataset.add("What injectors does the LX-900 use?", "BR-7741 injectors at 2,150 PSI.")

session.train_adapter("lx900-manual", dataset) do |progress|
  puts "iter #{progress.iteration}: loss=#{progress.loss}"
end
session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("lx900-manual")])
)
```

The runtime talks to a small Swift bridge (`native/llamero-mlx`) built on
`mlx-swift-lm`, loaded at runtime via `dlopen` - apps without the bridge built
automatically fall back to a deterministic mock bridge, so specs and non-Apple
development keep working. Build the real bridge with:

```bash
cd native/llamero-mlx && ./build.sh
crystal run examples/native_smoke_test.cr   # real on-device inference
```

### Audio (experimental)

The native track also ships an on-device speech runtime: speech-to-text with
NVIDIA Parakeet and text-to-speech with Kokoro, running through a second
Swift bridge (`native/llamero-audio`) built on
[FluidAudio](https://github.com/FluidInference/FluidAudio) - CoreML on the
Neural Engine, so transcription and synthesis never compete with the MLX LLM
for the GPU. Models download lazily on first use.

```crystal
audio = Llamero::Native::AudioRuntime.new   # Parakeet v3 + Kokoro defaults

result = audio.transcribe(Path["meeting.wav"])
result.text       # full transcript
result.segments   # word-level [{text, start_ms, end_ms}]

spoken = audio.speak("I found three problems in that file.", voice: "af_heart")
spoken.path       # wav file, ready to play
```

Streaming speech-to-text turns the same runtime into a live dictation
engine: push 16kHz mono `Float32` samples from your capture layer and
llamero streams text back — partial hypotheses while a phrase is being
spoken, and one completed utterance per detected end of utterance (Parakeet
EOU 120M, confirmed after a configurable silence debounce):

```crystal
stream = audio.start_stream # chunk_ms: 160, eou_debounce_ms: 1280

stream.on_partial { |text| print "\r#{text}" }              # live ghost text
stream.on_utterance { |utterance| handle(utterance.text) }  # completed phrases

while samples = capture.next_chunk # Slice(Float32), 16kHz mono
  stream.push(samples)
end

result = stream.finish # flushes + returns the full session transcript
result.text            # everything said
result.segments        # one {text, start_ms, end_ms} per utterance
```

Without the built audio bridge the same deterministic mock-fallback rule
applies (gate real-audio code on `audio.real_bridge?`). Build and verify with:

```bash
cd native/llamero-audio && ./build.sh
crystal run examples/native_audio_test.cr -- /path/to/speech.wav  # file STT + TTS (verified on-device)
crystal run examples/native_dictation_test.cr -- /path/to/speech.wav  # streaming STT
```

Status: file transcription and TTS are verified on-device; streaming STT is
implemented and spec-covered, pending on-device verification (see the
multimodal roadmap below). PCM-streaming TTS is a planned follow-up.

Design docs:

- [Native MLX roadmap](development_docs/native_mlx_roadmap.md)
- [Native MLX architecture](development_docs/native_mlx_architecture.md)
- [Multimodal roadmap (vision, speech-to-text, text-to-speech)](development_docs/multimodal_roadmap.md)
- [Llamero v2 roadmap](development_docs/v2_roadmap.md)

## Documentation for AI Coding Agents

Llamero ships its documentation in forms coding assistants can actually use,
so even small models can build with the library:

- **Skills** (`.claude/skills/`): task recipes for `cloud-providers`,
  `local-inference`, and `adapter-training`, written as complete programs
  with error→fix tables. With the [Ashard fork of
  shards](https://github.com/crimson-knight/shards), `shards install`
  copies them into your project as `.claude/skills/llamero--<name>/`.
- **[CLAUDE.md](CLAUDE.md)** and **[AGENTS.md](AGENTS.md)**: the condensed
  API contract for any agent harness.
- **A golden training dataset**
  ([training_data/llamero_api_qa.jsonl](training_data/llamero_api_qa.jsonl)):
  the API as prompt/completion pairs. Train a local model its own llamero
  adapter with `examples/train_llamero_docs_adapter.cr` - the library
  teaching a model to use the library:

```crystal
dataset = Llamero::Native::TrainingDataset.from_pairs_jsonl(
  "lib/llamero/training_data/llamero_api_qa.jsonl"
)
session.train_adapter("llamero-docs", dataset, config)
```

## Installation

Add the dependency to your `shard.yml`:

```yaml
dependencies:
  llamero:
    github: crimson-knight/llamero
```

Then run:

```bash
shards install
```

## Quick Start

### Define Your AI Client

```crystal
require "llamero"

# Create your application's AI client with failover
class MyAIClient < Llamero::Client
  def initialize
    super(
      primary: :openai,
      fallbacks: [:anthropic, :groq]
    )
  end
end

client = MyAIClient.new
```

### Basic Chat

```crystal
response = client.chat([
  Llamero::Message.user("What is the capital of France?")
])

puts response.content
# => "The capital of France is Paris."

puts "Provider: #{response.provider_used}"
# => "Provider: openai"
```

### Structured Output

Define a response schema using `BaseGrammar`:

```crystal
class PersonInfo < Llamero::BaseGrammar
  property name : String = ""
  property age : Int32 = 0
  property occupation : String = ""
end

response = client.chat_structured(
  [Llamero::Message.user("Generate a random person's info")],
  PersonInfo
)

person = response.parsed.not_nil!
puts "Name: #{person.name}, Age: #{person.age}"
```

### Grammar-constrained structured output (local llama.cpp)

`chat_structured` accepts a `generation_mode` (default `:auto`) that controls
*how* the model is held to your schema:

```crystal
backend = Llamero::LlamaCpp::CompletionBackend.new(model_path: "path/to/model.gguf")

response = backend.chat_structured(
  [Llamero::Message.user("File a ticket for the crashing login page")],
  Ticket,
  generation_mode: :grammar   # :grammar | :schema_prompt | :auto
)
response.parsed              # => Ticket (output was JSON from the first byte)
response.constraint_backend  # => "grammar"
```

In `:grammar` mode a GBNF grammar is derived from your `BaseGrammar` subclass
**at compile time** (same type reflection as the JSON Schema builder, so the
two can never disagree) and enforced during decoding - the model physically
cannot emit anything that will not parse as your type. Keys are emitted in
declaration order; that ordering is part of the grammar-mode contract.

Honest per-backend matrix - no backend pretends to constrain when it cannot:

| Backend | `:auto` | forced `:grammar` |
|---|---|---|
| `Llamero::LlamaCpp::CompletionBackend` (pinned llama.cpp) | GBNF when the type is within budget and the pinned build is installed; otherwise schema-prompt with an explicit `fallback_reason` + one-time warning | GBNF, or raises (`LlamaCppUnavailableError` / `GrammarBudgetExceededError`) |
| OpenAI / Groq / OpenRouter | native `response_format` json_schema strict (unchanged) | raises `UnsupportedGenerationModeError` |
| Anthropic | native structured output (unchanged) | raises |
| CLI-subprocess clients (Claude Code, ...) | unsupported, unchanged | raises |
| Native MLX (`ModelSession`) | schema-prompt (the Swift bridge drops the `schema` field and pinned mlx-swift-lm has no logit masking - grammar there would need a custom logit processor) | raises |

There is never a silent downgrade: forcing `:grammar` on a backend that
cannot constrain decoding raises, and `:auto` fallbacks always carry a reason.

**The complexity cliff.** Grammar-from-types genuinely falls over for deeply
complex types (llama.cpp hard-breaks past `MAX_REPETITION_THRESHOLD = 2000`,
and schema->grammar coverage drops steeply with schema complexity in
JSONSchemaBench). llamero refuses instead of lying, at compile time where
possible. The budget (initial numbers, revisited as we benchmark): max 128
rules, nesting depth 8, 6 optional fields per object (optionals become an
explicit 2^n subset alternation, never the pathological `x? x? x?` chains),
256 total alternatives, 4 union members (nilable/numeric-widening only), 4
levels of array/hash nesting, and **no recursive types** (v1 refuses bounded
recursion outright). Over-budget behavior:

- `T.to_gbnf` - compile error with the reason.
- `generation_mode: :grammar` - raises `GrammarBudgetExceededError` at runtime.
- `generation_mode: :auto` - falls back to schema-prompt + typed parse;
  `T.gbnf_fallback_reason` tells you why, and the first call logs a warning.

**The llama.cpp pin.** llama.cpp releases near-daily with breaking flag/API
changes, so llamero supports exactly ONE build:
`b9902` (commit `55edb2de442b50be0a29c2ed2ec88488560a96c5`), declared in
`src/llamacpp/support.cr` and built by `scripts/install_llamacpp.sh` into
`~/.llamero/llamacpp/b9902/bin/llama-completion` (or `$LLAMERO_HOME/...`).
`shards install` runs the installer opportunistically via postinstall; since
`--skip-postinstall` exists, a mandatory runtime probe fails closed - it
verifies the pinned path, the exact commit via `--version`, and the flag
surface, and it NEVER accepts a llama.cpp found on PATH (a working brew
install on the dev machine is exactly the false positive this kills). If the
probe fails you get the fix command in the error:

```sh
sh scripts/install_llamacpp.sh   # from lib/llamero/ when installed as a dependency
```

Pin upgrades are deliberate PRs, never automatic: bump the constants, clean
rebuild, flag-surface smoke, `.gbnf` + `--json-schema` enforcement smoke,
generated-grammar fixture suite against the new binary, benchmark smoke, and
a changelog of changed llama.cpp surfaces - and a pin bump is at least a
minor llamero release.

Performance note: we publish only numbers we have measured ourselves with the
4-arm protocol in the repo (base/tuned x unconstrained/grammar, matched
prompts, time-to-correct with retries on the failing arm's clock). Until
those runs land in this README, no speed claims here - what grammar mode
already guarantees is structural: output parses as your type or the call
raises with everything you need to debug.

### Streaming

```crystal
client.chat_stream([
  Llamero::Message.user("Tell me a short story")
]) do |chunk|
  print chunk
end
```

## Configuration

### Environment Variables

Set API keys as environment variables:

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
export GROQ_API_KEY="gsk_..."
export OPENROUTER_API_KEY="sk-or-..."
```

### Configuration File

Create `.llamero/config.yml` in your project directory:

```yaml
providers:
  openai:
    api_key: "sk-..."
    organization: "org-..."  # optional
  anthropic:
    api_key: "sk-ant-..."
  groq:
    api_key: "gsk_..."
  openrouter:
    api_key: "sk-or-..."

defaults:
  provider: openai
  model: gpt-4o
  temperature: 0.7
  max_tokens: 4096
```

**Priority order**: Explicit constructor values > Environment variables > Config file > Defaults

## Provider Failover

The unified `Client` automatically handles failover:

```crystal
class ResilientClient < Llamero::Client
  def initialize
    super(
      primary: :openai,
      fallbacks: [:anthropic, :groq],
      retry_config: Llamero::RetryConfig.new(
        max_retries: 3,
        base_delay: 1.second
      )
    )

    # Optional: Monitor failovers
    on_fallback do |from, to, error|
      Log.warn { "Failing over from #{from} to #{to}: #{error.message}" }
    end

    on_retry do |provider, attempt, error|
      Log.info { "Retry #{attempt} for #{provider}" }
    end
  end
end
```

### Retry Behavior

| Error Type | Behavior |
|------------|----------|
| Rate Limit (429) | Retry with exponential backoff |
| Server Error (5xx) | Retry with backoff |
| Auth Error (401/403) | Immediate failover (no retry) |
| Quota Exceeded (402) | Immediate failover |

## Direct Provider Access

For advanced use cases, access provider clients directly:

```crystal
# OpenAI
client = Llamero::OpenAIClient.new
response = client.chat([Llamero::Message.user("Hello!")])

# Anthropic
client = Llamero::AnthropicClient.new
response = client.chat([Llamero::Message.user("Hello!")])

# With custom settings
client = Llamero::OpenAIClient.new(
  api_key: "sk-...",
  default_model: "gpt-4o-mini",
  timeout: 5.minutes
)
```

## API Reference

### Message

```crystal
Llamero::Message.system("You are a helpful assistant")
Llamero::Message.user("Hello!")
Llamero::Message.assistant("Hi there!")
Llamero::Message.tool(content, tool_call_id, name)
```

### ChatResponse

```crystal
response.content        # String - the response text
response.model          # String - model used
response.usage          # Usage - token counts
response.finish_reason  # String - why generation stopped
response.parsed         # T? - parsed structured output
response.provider_used  # Symbol - which provider was used
response.attempts       # Int32 - total attempt count
```

### BaseGrammar

Inherit from `BaseGrammar` to define structured response schemas:

```crystal
class Analysis < Llamero::BaseGrammar
  property sentiment : String = ""
  property confidence : Float32 = 0.0
  property keywords : Array(String) = [] of String
end

# Get JSON Schema for the grammar
schema = Analysis.to_json_schema
```

### RetryConfig

```crystal
# Default configuration
Llamero::RetryConfig.new

# Aggressive retries
Llamero::RetryConfig.aggressive

# Conservative (fewer retries)
Llamero::RetryConfig.conservative

# No retries
Llamero::RetryConfig.no_retry

# Custom
Llamero::RetryConfig.new(
  max_retries: 5,
  base_delay: 500.milliseconds,
  max_delay: 30.seconds,
  exponential_base: 2.0,
  jitter: 0.1
)
```

## Development

```bash
# Run tests
crystal spec

# Type check
crystal build src/llamero.cr --no-codegen
```

## Contributing

Open an issue to discuss features before developing.

Branch naming:
- Bug fixes: `issue/1234-description`
- Features: `feature/1234-description`

1. Fork it (<https://github.com/crimson-knight/llamero/fork>)
2. Create your feature branch (`git checkout -b feature/description`)
3. Commit your changes (`git commit -am 'Add feature'`)
4. Push to the branch (`git push origin feature/description`)
5. Create a Pull Request

## Contributors

- [Seth Tucker](https://github.com/crimson-knight) - creator and maintainer
