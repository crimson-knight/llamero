---
name: cloud-providers
description: Call cloud AI APIs (OpenAI, Anthropic/Claude, Groq, OpenRouter) from Crystal with the llamero shard - chat, streaming, structured JSON output, embeddings, and automatic failover between providers. Use when the user wants to call an LLM API from Crystal, needs provider failover/retries, or wants typed structured responses from a cloud model.
---

# Cloud provider clients with llamero

llamero gives Crystal apps one client API over OpenAI, Anthropic, Groq, and
OpenRouter, with automatic retry and failover. Define one subclass of
`Llamero::Client` per app and use it everywhere.

`Llamero::Client` is **abstract** — you cannot `Llamero::Client.new`. Subclass
it, or use a concrete provider client directly (`Llamero::OpenAIClient.new`).

## Setup

API keys come from environment variables (or the project config file):

```bash
export OPENAI_API_KEY="sk-..."
export ANTHROPIC_API_KEY="sk-ant-..."
export GROQ_API_KEY="gsk_..."
export OPENROUTER_API_KEY="sk-or-..."
```

Only the providers you actually list need keys.

## Storage root

If the same app also uses llamero native models/adapters/audio, set the
app-owned storage root at boot before creating runtimes:

```crystal
Llamero.storage_root = Path.home.join(".scribe")
```

`LLAMERO_HOME=/path/to/root` is the env alternative; programmatic wins.

## Recipe: chat with failover (complete program)

```crystal
require "llamero"

class MyAIClient < Llamero::Client
  def initialize
    super(primary: :openai, fallbacks: [:anthropic, :groq])
  end
end

client = MyAIClient.new

response = client.chat([
  Llamero::Message.user("What is the capital of France?"),
])
puts response.content       # "The capital of France is Paris."
puts response.provider_used # :openai (or a fallback if openai failed)
```

Provider symbols: `:openai`, `:anthropic`, `:groq`, `:openrouter`.
Optional named args on `chat`: `model : String?`, `temperature : Float32?`,
`max_tokens : Int32?`.

## Recipe: structured JSON output into a Crystal object

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
puts "#{person.name}, #{person.age}, #{person.occupation}"
```

Schema classes inherit `Llamero::BaseGrammar` and **every property needs a
default value**. Failover automatically skips providers that lack structured
output support.

## Recipe: streaming

```crystal
client.chat_stream([Llamero::Message.user("Tell me a story")]) do |chunk|
  print chunk
end
```

`chat_stream` returns `Nil`; the content arrives only through the block.

## Recipe: retries, failover monitoring, direct clients

```crystal
class ResilientClient < Llamero::Client
  def initialize
    super(
      primary: :openai,
      fallbacks: [:anthropic],
      retry_config: Llamero::RetryConfig.new(max_retries: 3, base_delay: 1.second)
    )
    on_fallback do |from, to, error|
      Log.warn { "Failover #{from} -> #{to}: #{error.message}" }
    end
    on_retry do |provider, attempt, error|
      Log.info { "Retry #{attempt} on #{provider}" }
    end
  end
end
```

Retry presets: `RetryConfig.new` (default), `.aggressive`, `.conservative`,
`.no_retry`. Behavior: 429/5xx retry with exponential backoff; 401/403/402
fail over immediately without retrying.

Direct provider access (no failover wrapper):

```crystal
client = Llamero::OpenAIClient.new(default_model: "gpt-4o-mini")
response = client.chat([Llamero::Message.user("Hello!")])
```

Classes: `Llamero::OpenAIClient`, `Llamero::AnthropicClient`,
`Llamero::GroqClient`, `Llamero::OpenRouterClient`.

## Message helpers

```crystal
Llamero::Message.system("You are a helpful assistant")
Llamero::Message.user("Hello!")
Llamero::Message.assistant("Hi there!")
```

## ChatResponse fields

`content : String`, `model : String`, `usage` (token counts),
`finish_reason : String`, `parsed : T?` (structured calls only),
`provider_used : Symbol`, `attempts : Int32`.

## Errors and what they mean

| Error / symptom | Cause | Fix |
|---|---|---|
| `can't instantiate abstract class Llamero::Client` | Called `Llamero::Client.new` | Subclass it (see first recipe) |
| Error about no configured providers | Missing API key env vars | Export the key for each provider you listed |
| `Llamero::APIError` with status 401 | Wrong/expired API key | Check the env var value |
| All providers failed | Every provider errored | Inspect `error.message`; add `on_fallback` logging |
| `response.parsed` is nil after `chat_structured` | Should not happen on success — an error would have raised | Use `.not_nil!` after a successful call |

## Related

For **local on-device** inference without any API key, use the
`local-inference` skill (`Llamero::Native::MLXRuntime`). The `Message` and
`BaseGrammar` types are shared between cloud and native, so schemas and
conversations port across both.
