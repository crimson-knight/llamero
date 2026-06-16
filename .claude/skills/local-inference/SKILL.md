---
name: local-inference
description: Run AI models locally on Apple Silicon from Crystal with the llamero shard (Llamero::Native, MLX/Metal). Use when the user wants on-device or local LLM inference, local chat, token streaming, structured JSON output from a local model, or to load/keep a model resident in memory without cloud APIs like OpenAI. Also covers downloading mlx-community models and activating LoRA adapters.
---

# Local inference with llamero (Apple Silicon / MLX)

llamero runs language models locally on Apple Silicon through a Swift MLX
bridge. The model loads into memory **once** and stays resident; every chat,
stream, or structured call reuses it. No Python, no llama.cpp, no cloud API.

## Requirements — check these first

1. macOS on Apple Silicon (M1 or newer). On any other platform,
   `Llamero::Native` still compiles and runs, but uses a **mock bridge** that
   returns canned text. Check at runtime with `runtime.real_bridge?`.
2. The Swift bridge dylib must be built **once** per machine:

   ```bash
   # In a project that depends on llamero:
   cd lib/llamero/native/llamero-mlx && ./build.sh
   # Inside the llamero repo itself:
   cd native/llamero-mlx && ./build.sh
   ```

   `build.sh` installs `libLlameroMLXBridge.dylib` and `mlx.metallib` to
   `$LLAMERO_HOME/lib` when set, otherwise `~/.llamero/lib/`, where llamero
   finds them from any project. It requires Xcode with the Metal toolchain
   (`xcodebuild -downloadComponent MetalToolchain` if the build complains
   about a missing `metal` tool).
3. Models download automatically from Hugging Face on first load into
   the configured storage root's `models/` directory. The `mlx-community`
   conversions (including Gemma) are generally ungated and need no token.
   Gated repos (e.g. `google/*` originals) need `HF_TOKEN` set in the
   environment.

## Storage root

Default storage is `~/.llamero`. Apps that need app-owned AI data set this at
boot before creating runtimes:

```crystal
Llamero.storage_root = Path.home.join(".scribe")
```

`LLAMERO_HOME=/path/to/root` is the env alternative; programmatic wins. The
root controls local model downloads (`models/`), adapter artifacts
(`adapters/`), bridge lookup (`lib/`), and audio model caches
(`audio_models/`) when audio is configured. For app-owned bridge installs,
set `LLAMERO_HOME` when running `build.sh`. FluidAudio 0.15.2 still pins
English Kokoro G2P assets to its own TTS cache; see
`development_docs/storage_configuration.md`.

## Recipe: minimal chat (complete program)

```crystal
require "llamero"

runtime = Llamero::Native::MLXRuntime.new(
  model_id: "mlx-community/gemma-4-e2b-it-4bit"
)
abort "Build the MLX bridge first (see skill)" unless runtime.real_bridge?

session = runtime.start_session
session.load_model # downloads on first run, then loads into memory

response = session.chat([Llamero::Message.user("What is the capital of France?")])
puts response.content

runtime.close
```

Notes:
- `session.load_model` is **required** before any chat call. It returns
  `ModelLoadMetrics` (load_time_ms, memory_bytes).
- The response type is `NativeChatResponse`. The text is in
  `response.content` (NOT `.text`, NOT `.message`).
- `response.metrics` has `tokens_per_second`, `input_tokens`, `output_tokens`,
  `time_to_first_token_ms`.
- If you use a Qwen3 model instead, it emits `<think>...</think>` reasoning
  before the answer. Strip it when you only want the answer:
  `response.content.gsub(/<think>.*?<\/think>/m, "").strip`
  (Gemma models do not do this.)

## Recipe: streaming tokens

```crystal
session.chat_stream([Llamero::Message.user("Tell me a short story")]) do |chunk|
  print chunk
end
```

The block receives each token as it generates. The method still returns the
full `NativeChatResponse` at the end. Optional named args on `chat` and
`chat_stream`: `temperature : Float32?`, `max_tokens : Int32?`.

## Recipe: structured JSON output into a Crystal object

```crystal
require "llamero"

class CityInfo < Llamero::BaseGrammar
  property city : String = ""
  property country : String = ""
  property population : Int64 = 0
end

runtime = Llamero::Native::MLXRuntime.new(model_id: "mlx-community/gemma-4-e2b-it-4bit")
session = runtime.start_session
session.load_model

response = session.chat_structured(
  [Llamero::Message.user("Give me facts about Paris")],
  CityInfo
)
info = response.parsed.not_nil!
puts "#{info.city}, #{info.country}: #{info.population}"
```

Rules for schema classes:
- Inherit from `Llamero::BaseGrammar`.
- **Every property needs a default value** (`= ""`, `= 0`, `= [] of String`).
- llamero generates the JSON Schema, instructs the model, strips code fences
  and prose, and parses the result. You do not write any JSON handling.
- A bad model response raises `Llamero::Native::StructuredParseError` with the
  raw text in `error.raw_text`. Retry by calling `chat_structured` again — the
  model stays loaded, retries are cheap.

## Recipe: activate / deactivate a LoRA adapter

Adapters are removable "knowledge filters" applied to the resident model.
Activating or deactivating one never reloads the base model.

```crystal
runtime.adapters.register("sql-expert", Path["adapters/sql-expert"])

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([
    Llamero::Native::AdapterSlot.new("sql-expert"),
  ])
)
# ... chat calls now use the adapter ...
session.deactivate_adapters # back to the plain base model
```

- A registered adapter directory must contain `adapters.safetensors` and
  `adapter_config.json` (the standard mlx_lm format).
- v1 bridge limits: one adapter at a time, scale 1.0. Multiple slots or other
  scales raise `AdapterActivationError`.

### Fused activation — full base throughput

By default an adapter is applied as **live LoRA layers**, recomputed on every
forward pass. That costs throughput (~45% slower tokens on small 4-bit models;
the cost scales with the adapter's `num_layers`). Pass `fuse: true` to instead
**bake the adapter delta into the re-quantized base weights**, so generation
runs at full base speed with no per-token LoRA overhead:

```crystal
session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("sql-expert")]),
  fuse: true
)
session.active_adapters_fused? # => true
```

Trade-off: fusing **mutates** the resident base (and slightly re-quantizes it),
so a fused adapter cannot be cheaply unloaded. The next `activate_adapters` or
`deactivate_adapters` therefore **reloads the base model first** to restore a
clean slate — `load_count` increments, and `deactivate_adapters` still correctly
returns you to base behavior. Time-to-first-token is unchanged either way; the
cost the flag removes is purely per generated token.

- **`fuse: false`** (default): instant hot-swap, no reload — use when you switch
  adapters frequently.
- **`fuse: true`**: one-time fuse at activation, a reload only when you switch
  away, full base throughput throughout — use when one adapter stays active for
  a whole session (the typical on-device "one specialist per task" pattern).
  Measured on gemma-3-4b: unfused 51.8 tok/s vs fused 94.0 tok/s (= base).

- To **create** an adapter by training, use the `adapter-training` skill.

## Recipe: multiple specialized models (ModelPool)

The recommended app architecture is several small specialized models resident
in parallel — e.g. a dense specialist with a domain adapter plus a general
chat model — with the app routing each request by name.
`Llamero::Native::ModelPool` holds one runtime + session per named member:

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
puts pool.chat("chat", [Llamero::Message.user("Good morning!")]).content
pool.close
```

- Members load **lazily** on first use; the member's `default_stack` is
  auto-activated right after that first load. Configuration and adapter
  paths are validated eagerly at `add` time.
- `pool[name]` returns the ready `ModelSession` (loading it if needed) and
  raises `PoolMemberNotFoundError` for unknown names. `pool.names`,
  `pool.loaded_names`, and `pool.total_memory_bytes` surface state; memory
  budgeting is the app's decision.
- The pool has no queueing or scheduling — apps own concurrency. Calls on
  different sessions from different fibers are serialized by the GPU anyway.

## Choosing a model

| Model id | Use |
|---|---|
| `mlx-community/gemma-4-e2b-it-4bit` | Default for chat/inference. Gemma 4 (effective 2B), coherent instruction-following, no `<think>` blocks, ungated. **Not for adapter training** (see adapter-training skill) |
| `mlx-community/gemma-3-1b-it-4bit` | Default for adapter training; dense, small, fast to train |
| `mlx-community/gemma-4-E4B-it-qat-4bit` | Better quality chat, more memory |
| `mlx-community/Qwen3-0.6B-4bit` | Smallest coherent option, very fast (~240 tok/s on M1 Max); emits `<think>` blocks |
| `mlx-community/SmolLM-135M-Instruct-4bit` | Pipeline testing only — loads fast but output is incoherent. Never use it to judge quality |

Any MLX-format model from the `mlx-community` Hugging Face org with a
supported architecture works. Use 4-bit quantized variants on devices.

## Errors and what they mean

| Error / symptom | Cause | Fix |
|---|---|---|
| `runtime.real_bridge?` is `false` on a Mac | Bridge dylib not found | Run `build.sh` (see Requirements). Or set `LLAMERO_MLX_LIB=/path/to/libLlameroMLXBridge.dylib` |
| `SessionStateError: Model is not loaded` | Chat called before `load_model` | Call `session.load_model` first |
| `ModelLoadError` mentioning 401/403 or download failure | Gated model without token | `export HF_TOKEN=...`, or use an ungated model |
| `StructuredParseError` | Model emitted non-conforming JSON | Retry; lower temperature; use a larger model for complex schemas |
| `AdapterNotFoundError` | Stack references an unregistered name | `runtime.adapters.register(name, path)` first |
| Output is gibberish / repeated words | Model too small (SmolLM-135M) | Use the default Gemma model or larger |
| First run very slow before any output | One-time model download | Normal; watch progress via `session.on_event` (`ModelLoadProgressEvent`) |

## API names that do NOT exist (do not invent these)

- `runtime.chat(...)` — chat lives on the **session**, not the runtime.
- `response.text` / `response.message` — it is `response.content`.
- `Llamero::Native::Session` — the class is `Llamero::Native::ModelSession`,
  created via `runtime.start_session`.
- `session.unload_model` — close the session or runtime instead.
- `Message.new("hi")` — use the helpers: `Llamero::Message.user("hi")`,
  `Llamero::Message.system("...")`, `Llamero::Message.assistant("...")`.
