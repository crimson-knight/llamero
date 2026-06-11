# Llamero Native MLX Roadmap

**Status:** Phases 1-3 complete, plus adapter *training* (beyond original scope). Real MLX inference works end-to-end on Apple Silicon: Crystal downloads models (`ModelDownloader`), the Swift bridge (`native/llamero-mlx`) loads them from disk and streams tokens through the C ABI (Qwen3-0.6B-4bit: ~237 tok/s on M1 Max), repeated generations never reload the base model, and structured output parses into `BaseGrammar` classes. Adapter hot-swap is verified with a real adapter trained in-process: `ModelSession#train_adapter` runs QLoRA on the resident 4-bit model from a `TrainingDataset` of prompt/completion pairs (streaming loss/validation events, ~56s for 300 iterations on M1 Max), writes the mlx_lm artifact, and the adapter activates/deactivates with `load_count` staying at 1 (see `examples/native_adapter_training_test.cr`). Adapter training verified on dense models (gemma-3-1b-it-4bit: 3/3 on the docs-adapter test; Qwen3-0.6B: 2/3); Gemma 4 e-series trains but adapters have no inference effect (known issue, see multimodal_roadmap.md). Phase 5 (structured output) works via prompt-injected schemas; grammar-constrained decoding remains future work. Agent-facing docs ship with the shard (`.claude/skills/`, `CLAUDE.md`, `AGENTS.md` - distributed to consumers by the Ashard shards fork) along with a golden dataset (`training_data/llamero_api_qa.jsonl`) and `examples/train_llamero_docs_adapter.cr`, which dogfoods the training API to teach a local model llamero itself. Next: Phase 4 (desktop lab UI), multi-adapter stacks, document→dataset chunking pipeline, and the multimodal tracks (vision/STT/TTS - see [multimodal_roadmap.md](multimodal_roadmap.md)).
**Date:** 2026-04-25 (updated 2026-06-11)
**Track:** Apple-first native local inference for Crystal applications

Llamero already has a v2 track for cloud providers, CLI-backed providers,
structured output, tool use, and agent workflows. This native MLX track adds a
deeper local runtime pillar: Crystal applications should be able to keep a small
Apple Silicon optimized model resident, stream local responses, and hot-swap
small adapters without reloading the full model.

The first implementation loop is intentionally documentation-only. It makes the
vision durable before runtime files move around.

## Vision

Llamero should become the way to build Crystal AI applications that can run on
Apple hardware without handing control of the inference loop to a remote API.
The target experience is:

- A Crystal app starts a native runtime and loads one base model once.
- The model runs through Apple's MLX stack on Apple Silicon and Metal.
- The app streams chat responses and parses structured JSON into Crystal
  objects.
- The app can load, unload, reorder, scale, and compare LoRA-style adapters
  while the base model remains resident.
- The same public Crystal concepts can later support additional native
  backends, with llama.cpp/Metal as the first fallback path.

The proof application is a local desktop lab exposed through a Crystal-hosted
web UI. It should feel like a lightweight Obsidian-style workspace for training
data and adapter experiments, not a cloud provider dashboard.

## Default Backend

MLX is the default native path because it is Apple-first, built around unified
memory, and has first-party Swift support. The first bridge should target
`mlx-swift-lm`, not the Python `mlx-lm` package directly.

Primary upstream references:

- [MLX Swift LM](https://github.com/ml-explore/mlx-swift-lm)
- [MLX Swift Examples](https://github.com/ml-explore/mlx-swift-examples)
- [MLX LM LoRA docs](https://github.com/ml-explore/mlx-lm/blob/main/mlx_lm/LORA.md)

The fallback backend is llama.cpp with Metal. It remains valuable for GGUF,
broader model availability, and a stable C ABI, but it is not the first proof
target for this track.

## Product Proof

The first working proof is a Crystal-hosted local web app with four panels:

- Chat panel: streams local model tokens from the resident native runtime.
- Model status panel: shows loaded model, adapter stack, load time, memory, and
  tokens per second.
- Data browser: opens local Markdown and JSONL folders for prompt/training data
  review.
- Adapter lab: loads adapter directories, activates/deactivates them, reorders
  the stack, adjusts scale, and compares response runs.

The proof does not need to train adapters in v1. It needs to demonstrate that
the base model can stay loaded while adapter state changes.

## Future Crystal Surface

The native API should live under `Llamero::Native` so it can coexist with the
current provider clients and future workflow primitives.

```crystal
runtime = Llamero::Native::MLXRuntime.new(
  model_id: "mlx-community/Qwen3-0.6B-4bit",
  fallback_model_id: "mlx-community/SmolLM-135M-Instruct-4bit"
)

session = runtime.start_session
session.load_model

registry = Llamero::Native::AdapterRegistry.new
registry.register("sql", Path["adapters/sql"])
registry.register("tone", Path["adapters/tone"])

stack = Llamero::Native::AdapterStack.additive([
  Llamero::Native::AdapterSlot.new("sql", scale: 0.8),
  Llamero::Native::AdapterSlot.new("tone", scale: 0.4),
])

session.activate_adapters(stack)

session.chat_stream([
  Llamero::Message.user("Summarize the training examples as JSON.")
]) do |chunk|
  print chunk
end
```

Important types:

- `MLXRuntime`: owns process/runtime configuration and keeps the base model
  resident.
- `ModelSession`: owns one loaded model context, chat state, streaming,
  structured JSON accumulation, timings, and memory metrics.
- `AdapterRegistry`: validates and caches adapter metadata/handles by stable
  name.
- `AdapterStack`: describes the active adapter set, order, scale values, and
  composition mode.
- `NativeChatResponse(T)`: mirrors `ChatResponse(T)` but carries native runtime
  metrics and active adapter metadata.

## Adapter Strategy

The first adapter implementation should prove stock single-adapter load/unload
using MLX Swift LM's LoRA container APIs. Only after that works should Llamero
add custom stacked adapter behavior.

Composition modes:

- `:additive`: stable default. Multiple adapter deltas are treated as an
  additive composition. Order is recorded for UX and reproducibility, but should
  not be advertised as semantically meaningful.
- `:sequential`: experimental. Adapter order is intentionally meaningful and
  requires a custom runtime path. This mode should be guarded by explicit API
  naming and tests because it is research behavior, not stock LoRA behavior.

Every adapter activation should be traceable:

- Base model id and revision/path.
- Adapter names, paths, scales, checksums, and composition mode.
- Activation time and unload time.
- Whether the base model was reloaded. For the target behavior, this should be
  false.

## Phases

### Phase 0 - Vision Docs

Capture this native direction in durable docs and link it from the README.

Success:

- The docs explain why MLX is first.
- The docs define the future Crystal surface.
- The docs clearly separate this native track from the existing v2 provider/CLI
  track.

### Phase 1 - Native Runtime Skeleton

Add Crystal interfaces and a mocked bridge so specs can run on non-Apple CI and
without downloading a model.

Success:

- `Llamero::Native::MLXRuntime` can be instantiated against a mock bridge.
- Specs cover model state, adapter stack validation, and metrics shape.
- Runtime code is macOS-gated where needed.

### Phase 2 - Resident MLX Model Proof

Load a tiny MLX model once and stream chat through Crystal.

Defaults:

- Primary tiny model: Qwen3 0.6B 4-bit.
- Lower-memory fallback: SmolLM 135M 4-bit.

Success:

- First model load returns timing and memory metrics.
- Repeated chat calls do not reload the base model.
- Token streaming works through the Crystal API.

### Phase 3 - Adapter Hot-Swap

Implement adapter registration and activation.

Success:

- A single LoRA adapter can load and unload while the base model remains
  resident.
- The active adapter stack is visible in response metadata.
- Adapter errors are surfaced without killing the resident model session.

### Phase 4 - Desktop Lab UI

Build the Crystal `HTTP::Server` based local web UI.

Success:

- Chat streams through SSE or WebSocket.
- Local folders can be browsed for Markdown and JSONL files.
- Adapter order/scale controls update the active runtime state.
- Comparison runs can be saved as JSONL traces.

### Phase 5 - Structured Output

Reuse the existing JSON schema/`BaseGrammar` direction for local models.

Success:

- Streamed JSON can be accumulated and parsed into Crystal objects.
- Parse failures include the raw response and adapter stack metadata.
- Structured retries can run without reloading the base model.

## Test Plan

- Docs: verify links and consistency with `development_docs/v2_roadmap.md`.
- Crystal runtime: specs for state transitions, adapter registry validation,
  stack validation, and structured parse success/failure.
- Swift bridge: unit tests for load model, generate, load adapter, unload
  adapter, and error mapping.
- Integration: macOS-only smoke test with one tiny MLX model and one sample
  adapter.
- UI: browser test for chat streaming, data browsing, adapter reorder, scale
  changes, and model status updates.

## Non-Goals For The First Native Loop

- Training adapters inside Llamero.
- Shipping an iOS app.
- Building a native SwiftUI UI.
- Supporting every MLX model family.
- Creating a generalized multi-backend abstraction before MLX is proven.
- Making adapter order meaningful in the default additive mode.

## Open Questions

- What adapter artifact format should Llamero bless first: MLX adapter
  directories, safetensors-only folders, or a Llamero manifest wrapping either?
- Should adapter comparison traces live in `.llamero/runs` or a user-selected
  project folder?
- Should the first UI expose training-data editing or remain read-only while the
  runtime stabilizes?
- How much of the bridge should be shipped as a prebuilt library versus built
  locally by `shards install` or a setup script?
