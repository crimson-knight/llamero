# llamero — guide for AI coding agents

llamero is a Crystal library for building AI applications. It has two
independent tracks that share the same `Message` and `BaseGrammar` types:

1. **Cloud providers** (`Llamero::Client` + provider clients): OpenAI,
   Anthropic, Groq, OpenRouter with automatic retry/failover, streaming, and
   structured JSON output parsed into Crystal classes.
2. **Native local inference** (`Llamero::Native`): runs MLX models locally on
   Apple Silicon through a Swift bridge — resident model, token streaming,
   structured output, LoRA/QLoRA adapter hot-swap, and **in-process adapter
   training**. No Python.
3. **Pinned llama.cpp track** (`Llamero::LlamaCpp`): grammar-constrained
   structured output (GBNF derived from Crystal types at compile time) through
   a subprocess seam to EXACTLY ONE supported llama.cpp build, installed by
   `scripts/install_llamacpp.sh` and enforced by a fail-closed runtime probe
   that never accepts a PATH llama.cpp. Additive and optional — cloud-only or
   MLX-only users never need it. ("No llama.cpp" was v2 law until this track;
   the revisit is owner-sanctioned and confined to `src/llamacpp/`.)

## Which API do I need?

| Task | Use | Detailed skill |
|---|---|---|
| Call OpenAI/Claude/Groq/OpenRouter, failover, retries | Subclass `Llamero::Client` | `cloud-providers` |
| Run a model locally on a Mac, no API key | `Llamero::Native::MLXRuntime` | `local-inference` |
| Typed JSON output from any model | `chat_structured` + a `Llamero::BaseGrammar` subclass | both skills |
| Teach a local model new facts/documents; LoRA/QLoRA | `session.train_adapter` | `adapter-training` |
| Toggle learned knowledge on/off at runtime | `session.activate_adapters` / `deactivate_adapters` | `local-inference` |
| Decode-time schema enforcement (output physically cannot fail to parse) | `Llamero::LlamaCpp::CompletionBackend#chat_structured` with `generation_mode: :grammar` | README "Grammar-constrained structured output" |

Minimal rules that prevent most mistakes:

- `require "llamero"` is the only require.
- `Llamero::Client` is abstract — subclass it; never `Llamero::Client.new`.
- Native chat lives on a session: `runtime.start_session`, then
  `session.load_model` (required), then `session.chat(...)`.
- Response text is always `.content`; structured results are `.parsed`.
- `BaseGrammar` schema properties all need default values.
- Native track on a machine without the built Swift bridge silently uses a
  deterministic **mock**. Gate real-inference code on `runtime.real_bridge?`.

## Storage root

Default storage is `~/.llamero`. Apps that own their AI data directory must set
the root at boot before creating runtimes:

```crystal
Llamero.storage_root = Path.home.join(".scribe")
```

`LLAMERO_HOME=/path/to/root` also works; the programmatic setter wins. The root
controls local model downloads (`models/`), trained adapters (`adapters/`),
bridge lookup (`lib/`), and configured audio model caches (`audio_models/`).
FluidAudio 0.15.2 still hardcodes English Kokoro G2P assets under its TTS
cache; see `development_docs/storage_configuration.md` before promising fully
relocated TTS text synthesis.

## Working on the llamero repo itself

```bash
shards install                          # dependencies
crystal spec                            # full suite (runs anywhere; native uses MockBridge)
crystal build src/llamero.cr --no-codegen   # fast type check
cd native/llamero-mlx && ./build.sh     # build the Swift MLX bridge (Apple Silicon, one-time)
crystal run examples/native_smoke_test.cr            # real on-device inference check
crystal run examples/native_adapter_training_test.cr # real QLoRA training check
```

Layout:

- `src/clients/` — cloud track: `client.cr` (failover), one file per provider,
  `retry_config.cr`, `provider_config.cr`, `cli/` (CLI-subprocess backends).
- `src/native/` — native track: `mlx_runtime.cr`, `model_session.cr` (chat /
  structured / training), `adapters.cr`, `training.cr`, `model_downloader.cr`,
  `mlx_bridge.cr` (dlopen FFI), `mock_bridge.cr`, `events.cr`, `errors.cr`.
- `native/llamero-mlx/` — Swift package exposing the C ABI over mlx-swift-lm.
- `src/llamacpp/` — pinned llama.cpp track: `support.cr` (THE pin + probe),
  `runner.cr` (subprocess seam + MockRunner), `completion_backend.cr`.
  `src/grammars/gbnf_builder.cr` derives GBNF from types at macro time;
  over-budget types are refused (compile-time via `T.to_gbnf`, runtime via
  forced `:grammar`) — see the README for the complexity budget.
- `scripts/install_llamacpp.sh` — builds the pinned llama.cpp tag into
  `~/.llamero/llamacpp/<tag>/`; run by shard.yml postinstall, safe to re-run.
  Pin bumps are deliberate PRs (bump constants in `src/llamacpp/support.cr`,
  rebuild, re-run enforcement smokes + fixture suite, changelog) and at least
  a minor version bump.
- `spec/native/` — runs against MockBridge, no model downloads needed.
- `training_data/` — golden Q&A dataset about llamero's own API, used to
  train the dogfood docs adapter (`examples/train_llamero_docs_adapter.cr`).
- `development_docs/native_mlx_architecture.md` — bridge ABI contract and the
  hard-won constraints (callbacks on calling thread; bridge must never depend
  on the main dispatch queue; Crystal owns model downloads).

Repo conventions and gotchas:

- Specs must pass without the Swift bridge and without network access —
  anything touching real inference belongs in `examples/`, not `spec/`.
  The llama.cpp track follows the same law via `MockRunner`; the one live
  grammar spec self-skips unless the pinned build is installed and
  `LLAMERO_SPEC_GGUF` points at a model.
- The C ABI is the compatibility boundary: changing
  `native/llamero-mlx/Sources/LlameroMLXBridge/Bridge.swift` exports requires
  matching `src/native/mlx_bridge.cr` and a rebuild via `build.sh`.
- Crystal version gotchas that have bitten here before: block-captured
  variables don't type-narrow (copy to a local first); `ensure` is a reserved
  word; ivars holding dlopen'd `Proc`s need explicit type declarations.
- Bridge v1 intentionally rejects multi-adapter stacks and non-1.0 scales
  rather than silently approximating.

## When llamero is a dependency in another project

The shard ships these skills and docs; the Ashard shards fork installs them
into the consuming project's `.claude/` namespaced as `llamero--<skill>`.
Source lives at `lib/llamero/`, so the bridge build is
`cd lib/llamero/native/llamero-mlx && ./build.sh`. The build scripts install
to `$LLAMERO_HOME/lib` when that env var is set, otherwise `~/.llamero/lib/`.
Runtime model and adapter paths come from `Llamero.storage_root`.
