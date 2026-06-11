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
  model_id: "mlx-community/Qwen3-0.6B-4bit"
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

Design docs:

- [Native MLX roadmap](development_docs/native_mlx_roadmap.md)
- [Native MLX architecture](development_docs/native_mlx_architecture.md)
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
