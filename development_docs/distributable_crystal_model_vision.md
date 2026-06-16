# Distributable Crystal-expert model — vision & multi-phase plan

## The dream (end state)

A library author writes a library, runs one command, and ships a **training
filter** (a LoRA adapter) alongside it. Any AI coding assistant that loads that
filter instantly has accurate, working knowledge of the library's API and
idioms — no in-context teaching, no doc-stuffing, far fewer tool calls and tokens.

Concretely, Agency distributes:
- a **public Crystal-expert base** (a small, edge-capable model that knows the
  Crystal language deeply),
- an **Amber adapter** on top (the v2 DSLs and how they're used),
- **Agency-private product adapters** on top of that,
- and the **pipeline itself baked into an Agency Crystal compiler fork**, so every
  Agency project and open-source project gets doc→data→adapter generation for free.

This document organizes that into stages that build on what's already shipped in
`development_docs/training_methods_toolchain.md`.

## What already exists (the foundation — do not rebuild)

- **Training methods, on-device, proven:** unsupervised continued-pretraining
  (`from_text`/`from_documents`), SFT (`from_pairs_jsonl`), expert-iteration RL
  (`PracticeLoop` + `Rubric`), DPO (`PreferenceDataset`), and GRPO — both
  Crystal-orchestrated (`WeightedDataset`) and **bridge-driven** with a
  reward-callback FFI (`session.grpo_train`), KL-anchored for multi-round
  stability.
- **Docs → data, deterministic + valid-by-construction:** `DocExtractor` (pulls
  authored examples from `crystal docs --format=json` and markdown),
  `ExampleGenerator` (mix-and-match valid variations, compile-verified),
  `from_corpus_jsonl` (kind-tagged corpus → trainable dataset).
- **Adapter mechanics:** train / activate / deactivate / **fuse-on-activate**
  (bake an adapter into the re-quantized base at full throughput).
- **Verifiable rewards:** `crystal build --no-codegen` ("no errors") and
  `crystal tool format --check` ("no changes") as objective, on-device reward
  signals — the heart of the RL story.

## Two decisions that shape the architecture

### 1. Order of learning: unsupervised → SFT → RL. You're right; here's why.

You **cannot** go straight to RL for a domain the base doesn't already know.
RL (GRPO/expert-iteration) only amplifies signal that the model's *own*
generations already contain: it samples K completions, scores them, and pushes
toward the better ones. If the model knows nothing about Amber's new DSLs, every
sample scores ~0, there's no variance, the advantage is zero, and there's
nothing to learn from — the cold-start we hit empirically (which is why GRPO
needed a seed). **RL refines capability; it does not instil knowledge.**

So the pipeline is:
1. **Unsupervised** continued-pretraining on the raw docs/source — instils the
   domain's facts, vocabulary, and patterns. (`from_documents`)
2. **SFT** on the doc→data generator's **valid-by-construction** examples —
   instils idiomatic usage and output format, cheaply and at high quality.
3. **RL last** (DPO / GRPO with the compile/format/test rubric) — *polishes* for
   verifiable correctness past what the SFT data alone reaches.

The nuance that honours your preference: where we **have a correct target**
(the generator produced it), SFT is the right, efficient tool — "iterate toward
the example" is just SFT. Where we only have a **verifier** (does it compile? do
its tests pass?) but no single target, RL is the right tool. We do both, in
order. For general Crystal (which strong code bases partly know) RL can start
earlier; for genuinely-new DSLs, unsupervised+SFT must come first.

### 2. Stacking trained LoRA adapters: yes mathematically, but fuse-forward is the production path.

A LoRA is an additive low-rank delta: `W' = W + scale·(B·A)`. N adapters trained
on the same base could in principle be summed: `W + Σ ΔWᵢ`. But:

- **Each adapter was trained assuming an unmodified base.** Stacked at runtime,
  adapter B sees A's delta as unseen noise (and vice versa) — the deltas can
  interfere, and the more you stack the worse it gets. Clean composition is not
  guaranteed.
- **The bridge rejects runtime multi-stacks today** (Bridge.swift:728) — it's a
  deliberate v1 limit, not a casual gap.
- **Fuse-forward composes cleanly and is proven.** Train the Crystal adapter →
  `fuse` it into the (re-quantized) base → train the Amber adapter *on that
  Crystal-aware base* → fuse → train the Agency-private adapter on the
  Crystal+Amber base. Each stage is trained against the exact base it will run
  on, so there's no interference. The fuse work already validated one stage
  preserves correctness (4/4); the open question is compounding re-quant error
  across N stages (Phase C measures it).

**Distribution model that gets the best of both:**
- Ship the **public Crystal base** = a small Gemma with the Crystal adapter fused
  in (one checkpoint, fast, no interference).
- A library author trains **one adapter on that Crystal base** and ships it; a
  consumer loads exactly one adapter (trained against the base it runs on) — no
  runtime stacking needed, full modularity at the distribution layer.
- Agency's internal stack fuses forward (Crystal→Amber→private) into its own base
  or keeps the last layer as the active adapter.

So: **modular at the distribution layer (one adapter per artifact, each trained
on the right base), fused at the composition layer.** Runtime n-way stacking
stays a *research* option (Phase C experiment) — useful if it proves stable, but
not the critical path.

## The plan

### Phase A — Data acquisition & curation (the agent loop)
Turn loose, messy documentation into a versioned, phase-tagged corpus.
- **Sources:** Amber v2 beta docs, guides, READMEs, and *source code* (its new
  DSLs and their usage); Crystal stdlib + language docs.
- **Mechanism — a Workflow-orchestrated loop:** the main loop (me) plans and
  judges; minor agents (Haiku/Sonnet) each take a doc source and emit candidate
  examples — unsupervised text chunks, SFT pairs ("how do I X?" → idiomatic
  code), and preference pairs. **Every code example is gated by the deterministic
  verifier** (`ExampleGenerator.compiles?` / `crystal build`) so only-correct
  examples survive — no hallucinated APIs.
- **Output:** kind-tagged JSONL corpora (`text|pair|preference|trajectory`),
  bucketed into phases (language → framework → product), with provenance.
- **Build:** a `Llamero::Training::Curator` (or a saved Workflow) that drives the
  fetch → generate → verify → bucket loop.

### Phase B — The public Crystal-expert base
- **Pick the base:** small, ungated, edge-capable, non-Chinese — gemma-3-1b for
  edge, gemma-3-4b for desktop (both proven). Distributing Gemma fine-tunes is
  permitted under the Gemma Terms (verify attribution/redistribution clauses).
- **Train the Crystal adapter:** unsupervised on the Crystal corpus → SFT on
  verified examples → RL polish with the compile/format rubric.
- **Distribute:** the Crystal adapter, and/or a fused "crystal-base" checkpoint.
- **Validate:** held-out Crystal tasks — compile %, format %, and a small suite of
  "write idiomatic X" rubric checks.

### Phase C — Layered specialization (+ the stacking experiment)
- **Prove stacking first** (the experiment you flagged): train two adapters on
  one base, then (a) lift the bridge multi-stack limit and measure runtime
  sum-delta composition vs (b) fuse-forward; quantify interference and N-stage
  re-quant drift. Decide the production rule from data.
- **Build the Amber adapter** on the Crystal base (fuse-forward), validated on
  Amber-specific tasks; then Agency-private on the Crystal+Amber base.

### Phase D — Crystal compiler fork integration
- Make the pipeline first-class in the Agency Crystal fork: a `crystal training`
  (or `crystal docs --emit-training`) subcommand that walks a project's docs and
  emits the kind-tagged corpus natively (extending `Crystal::Doc`), with an opt
  to train/ship an adapter. Every project gets it for free.
- llamero stays the runtime/training engine the fork shells into (or links).

### Phase E — Distribution & the "training filter" product
- A standard package format + naming/registry convention so a library ships
  `name.adapter` (adapter weights + `adapter_config.json` + the base it targets +
  provenance/metrics).
- Consumer-side: how an AI assistant discovers the project's dependencies, fetches
  the matching adapters, and activates the right one (fused for the session).
- The payoff: instant working knowledge per dependency, fewer tool calls, lower
  cost.

## Honest unknowns / things to prove
- N-stage fuse-forward re-quant error compounding (Phase C).
- Runtime n-way LoRA stacking stability (Phase C) — may or may not be worth
  supporting.
- How much a 1b/4b base can actually *hold* (Crystal + Amber + a product) before
  capacity saturates — may force a larger desktop base for the full stack.
- Gemma redistribution terms for shipping fine-tuned checkpoints/adapters.
- The agent-loop data quality at scale: verification gates correctness, but
  coverage/diversity of the generated corpus needs a completeness critic.

## Suggested first /goal
Phase A end-to-end on a *small* slice: point the curation loop at the Amber v2
beta docs + source, produce a verified kind-tagged corpus, and run the
unsupervised→SFT→RL pipeline to produce a first **Amber-on-Crystal** adapter —
proving the whole chain (fetch → generate → verify → multi-method train → working
adapter) before scaling the data.
