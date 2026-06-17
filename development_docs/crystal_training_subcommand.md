# `crystal training` subcommand (Phase D)

The doc → data → adapter pipeline as a first-class command, so any project turns
its own documentation into training data — and optionally a distributable
training filter — with one invocation. This is the piece the vision bakes into an
Agency Crystal compiler fork so every project gets it for free.

Implemented as `Llamero::Native::CrystalTraining` (`src/native/crystal_training.cr`)
with a binary entry point at `src/tools/crystal_training.cr` (shard target
`crystal-training`).

```bash
shards build crystal-training          # -> bin/crystal-training
```

## Why a subcommand, and the fork boundary

The compiler already knows how to walk a project's documented API — that's what
`crystal docs` does. Training data extraction is the *same walk* with a different
emitter. So the natural home is the compiler: a `crystal training` subcommand
that reuses `Crystal::Doc`'s type tree instead of re-parsing.

This prototype shells `crystal docs --format=json` rather than linking the
compiler, but the boundary is identical: walk the documented types, pull the
authored code blocks, emit a kind-tagged corpus, train. Upstreaming into the fork
means swapping the subprocess for a direct `Crystal::Doc` call — the
`DocExtractor` ingestion logic is unchanged. llamero stays the runtime/training
engine the fork shells into (or links).

## Subcommands

### `extract` — docs → kind-tagged corpus (no model)

```bash
# From a shard (runs crystal docs --format=json under the hood):
crystal-training extract --shard . --out corpus.jsonl --kind pair

# From standalone markdown (e.g. an Amber gitbook), file or directory:
crystal-training extract --markdown docs/ --out amber.jsonl --kind text
```

- `--kind pair` emits SFT pairs (`{kind, prompt, completion}`); `--kind text`
  emits unsupervised chunks (`{kind, text}`).
- Crystal-only by default (drops shell/yaml/etc. fences); `--all-languages`
  keeps everything. Crystal-ecosystem docs that fence Crystal as ` ```ruby ` are
  normalized to Crystal, so the corpus isn't dominated by mislabeled examples.
- `--verified` keeps only examples that type-check (`crystal build --no-codegen`)
  — the deterministic verifier gate from the vision. It drops mislabeled shell
  blocks (a bare-fenced `$ amber db migrate` reads as Crystal otherwise) and
  snippets referencing unavailable symbols. Use it for language/stdlib corpora;
  bare framework examples need the framework in scope to compile, so it
  over-rejects there (train those unverified, or compile within the project).
- No `--out` streams the corpus to stdout (pipe it onward).

Every example is authored (pulled verbatim from real docs), so the corpus is
grounded — no hallucinated APIs. (Valid-by-construction *generation* on top of
these chunks is `ExampleGenerator`, compile-verified.)

### `adapter` — docs → unsupervised + SFT → optional `.filter`

```bash
crystal-training adapter --markdown docs/ \
  --model mlx-community/gemma-3-1b-it-4bit \
  --name amber --library amber --library-version 2.0.0-dev \
  --ship dist/amber.filter
```

Extracts the corpus, then runs the `StagedPipeline` (unsupervised continued-
pretraining on the doc text → SFT on the doc pairs, fused forward) on the chosen
base, and — with `--ship` — packages the result as a distributable training
filter (Phase E). Without the native MLX bridge built it exits 2 with a clear
message (the extract path needs no bridge).

## Tested

`spec/native/crystal_training_spec.cr` (bridge-free): usage/help, unknown
subcommand, markdown extraction (Crystal-only vs `--all-languages`), `--out`
corpus files, `--kind` validation, and the required-argument errors. The
`adapter` path's training + packaging is covered by the StagedPipeline and
TrainingFilter validations.

## Open items

- Direct `Crystal::Doc` integration in the Agency fork (drop the subprocess).
- A `--ship`-with-RL path (add a GRPO polish stage with the compile/format rubric)
  once a project supplies held-out prompts.
- `--base-filter` to train fused-forward atop an existing filter (Crystal → Amber).
