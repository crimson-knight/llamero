# Native MLX Architecture

**Status:** architecture target for the native MLX track
**Date:** 2026-04-25

This document describes how Llamero should expose Apple-native local inference
to Crystal applications while keeping the MLX runtime isolated behind a small
native bridge.

## Architecture Goals

- Crystal owns the public API, app behavior, structured output, and local web UI.
- MLX Swift owns Apple Silicon model execution, Metal acceleration, tokenizer
  integration, LoRA loading, and generation internals.
- The bridge boundary stays small, explicit, and testable.
- A base model can remain resident while adapter state changes.
- Non-Apple development and CI can use a mock bridge.

## Runtime Shape

```text
Crystal app / local web UI
        |
        v
Llamero::Native API
        |
        v
Crystal FFI binding
        |
        v
C ABI shim
        |
        v
Swift MLX runtime package
        |
        v
mlx-swift-lm / MLX / Metal
```

The Crystal API should never call MLX Swift directly. It talks to a C ABI shim
that owns opaque runtime/session handles. Swift owns the real MLX objects behind
those handles.

## Crystal Modules

### `Llamero::Native::MLXRuntime`

Owns native runtime configuration.

Responsibilities:

- Select model id/path and fallback model id/path.
- Select memory policy and cache limits.
- Create and close `ModelSession` instances.
- Report whether the runtime is using the real MLX bridge or a mock bridge.

Target initializer:

```crystal
runtime = Llamero::Native::MLXRuntime.new(
  model_id: "mlx-community/Qwen3-0.6B-4bit",
  fallback_model_id: "mlx-community/SmolLM-135M-Instruct-4bit",
  cache_limit_bytes: 64 * 1024 * 1024,
  bridge: Llamero::Native::Bridge.auto
)
```

### `Llamero::Native::ModelSession`

Owns one loaded model context.

Responsibilities:

- Load the base model once.
- Track loaded/unloaded/error state.
- Stream chat responses.
- Accumulate structured JSON.
- Activate adapter stacks.
- Preserve metrics for the model and each generation call.

Important invariant:

- `activate_adapters` must not reload the base model unless the bridge returns a
  typed error saying the adapter is incompatible and recovery requires reload.

### `Llamero::Native::AdapterRegistry`

Maps human-readable adapter names to validated local adapter artifacts.

Responsibilities:

- Validate adapter paths and metadata.
- Compute stable checksums.
- Cache adapter descriptors.
- Keep adapter metadata separate from active runtime state.

Target usage:

```crystal
registry = Llamero::Native::AdapterRegistry.new
registry.register("sql", Path["adapters/sql"])
registry.register("support-tone", Path["adapters/support-tone"])
```

### `Llamero::Native::AdapterStack`

Describes the adapters active for a request/session.

Fields:

- `slots : Array(AdapterSlot)`
- `mode : AdapterStack::Mode`
- `created_at : Time`

Modes:

- `Additive`: default. Adapter deltas compose together; ordering is stored for
  repeatability but should not imply semantic ordering.
- `Sequential`: experimental. Ordering is meaningful and must be implemented by
  a custom runtime path.

Validation:

- Adapter names must be unique within a stack.
- Scale must be finite and default to `1.0`.
- `Sequential` must require an explicit experimental flag until implemented.
- Empty stack means "base model only".

## Bridge Boundary

The native bridge should expose opaque handles and JSON event payloads so the
Crystal side remains stable while Swift implementation details evolve.

Conceptual C ABI:

```c
typedef struct llamero_mlx_runtime llamero_mlx_runtime_t;
typedef struct llamero_mlx_session llamero_mlx_session_t;

llamero_status_t llamero_mlx_runtime_create(
  const char *json_config,
  llamero_mlx_runtime_t **out_runtime
);

llamero_status_t llamero_mlx_session_create(
  llamero_mlx_runtime_t *runtime,
  llamero_mlx_session_t **out_session
);

llamero_status_t llamero_mlx_session_load_model(
  llamero_mlx_session_t *session,
  const char *json_request /* {"model_path": "..."} - resolved Crystal-side */
);

llamero_status_t llamero_mlx_session_activate_adapters(
  llamero_mlx_session_t *session,
  const char *json_adapter_stack
);

llamero_status_t llamero_mlx_session_generate_stream(
  llamero_mlx_session_t *session,
  const char *json_request,
  llamero_stream_callback callback,
  void *user_data
);

void llamero_mlx_session_free(llamero_mlx_session_t *session);
void llamero_mlx_runtime_free(llamero_mlx_runtime_t *runtime);
```

Bridge payloads should be JSON at first because the boundary is still moving.
If profiling shows bridge JSON overhead matters, replace individual hot payloads
with structs later.

Two constraints discovered while building the real bridge (2026-06-11):

- Event callbacks must always fire on the calling thread. Crystal's GC cannot
  tolerate callbacks from foreign threads, so the Swift side pumps its async
  work through an internal queue that the caller's thread drains.
- The host process never services the dispatch main queue, so the bridge must
  not depend on the main actor. The Swift HuggingFace downloader does, which
  is why model downloading lives in Crystal (`ModelDownloader`) and the bridge
  always loads from a local directory.

## Events

Streaming should use typed events on the Crystal side:

- `ModelLoadStarted`
- `ModelLoadProgress`
- `ModelLoaded`
- `AdapterActivated`
- `TokenDelta`
- `StructuredJsonDelta`
- `GenerationCompleted`
- `RuntimeMetric`
- `NativeError`

All events should carry:

- `session_id`
- `model_id`
- `adapter_stack_id`
- `created_at`

Generation completion should carry:

- `input_tokens`
- `output_tokens`
- `tokens_per_second`
- `time_to_first_token_ms`
- `total_time_ms`
- `active_adapter_stack`

## Structured Output

The native track should reuse Llamero's JSON schema direction:

```crystal
class TrainingDataSummary < Llamero::BaseGrammar
  property folder_name : String = ""
  property usable_examples : Int32 = 0
  property warnings : Array(String) = [] of String
end

response = session.chat_structured(
  [Llamero::Message.user("Summarize this folder.")],
  TrainingDataSummary,
  adapter_stack: stack
)

summary = response.parsed.not_nil!
```

Implementation notes:

- The Crystal side owns schema generation.
- The prompt layer asks the local model for JSON matching the schema.
- The stream layer accumulates JSON candidates.
- Parse failures return a typed error with raw text, schema name, and adapter
  metadata.

## Adapter Lifecycle

Recommended first lifecycle:

1. Register adapter metadata in Crystal.
2. Ask bridge to load one adapter into the resident model.
3. Generate with that adapter.
4. Ask bridge to unload adapter.
5. Generate again with base model only.

Only after this works should Llamero implement multi-adapter stacks.

For stack comparison, each run should write a JSONL trace:

```json
{"event":"run_started","model_id":"...","stack":[{"name":"sql","scale":0.8}]}
{"event":"token_delta","text":"..."}
{"event":"run_completed","tokens_per_second":42.1,"base_model_reloaded":false}
```

## Local Web UI

The proof UI should be served by Crystal:

- `HTTP::Server` serves static assets and JSON APIs.
- SSE or WebSocket streams generation events.
- File browsing is read-only at first.
- Runtime state is pulled from the same `Llamero::Native` API app developers
  will use.

Suggested endpoints:

- `GET /api/native/status`
- `POST /api/native/model/load`
- `POST /api/native/chat`
- `GET /api/native/chat/:run_id/events`
- `GET /api/native/files?path=...`
- `POST /api/native/adapters/register`
- `POST /api/native/adapters/activate`
- `POST /api/native/runs/compare`

## Error Model

Native errors should be explicit and recoverable where possible:

- `ModelLoadError`
- `ModelUnavailableError`
- `AdapterNotFoundError`
- `AdapterIncompatibleError`
- `AdapterActivationError`
- `GenerationError`
- `BridgeUnavailableError`
- `UnsupportedPlatformError`

Error payloads should include:

- Human message.
- Bridge/backend code.
- Recoverability hint.
- Whether the base model remains loaded.

## Platform Strategy

Initial support:

- macOS on Apple Silicon.
- Mock bridge on any platform for Crystal specs.

Later support:

- iOS once the Swift bridge and app embedding story is stable.
- llama.cpp/Metal backend under the same `Llamero::Native` concepts.

Unsupported at first:

- Windows.
- Linux native MLX runtime.
- Remote MLX server mode.

## Implementation Guardrails

- Keep runtime docs and current provider/CLI docs separate.
- Avoid forcing Swift or MLX dependencies into normal shard installs until the
  native track has a build story.
- Do not hide adapter reloads. If the base model reloads, report it.
- Do not claim adapter order improves results in additive mode.
- Make mock bridge behavior deterministic so specs remain fast and stable.
