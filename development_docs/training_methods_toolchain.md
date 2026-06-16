# Multi-method training toolchain — design

The goal: make llamero a place where a model gains **a stack of specialized
adapters, one per learning method and per knowledge set**, and where the training
data for those adapters can be **generated from documentation** in a consistent
format. Unsupervised continued-pretraining teaches the domain, supervised
fine-tuning teaches the task, and preference/RL optimizes for a verifiable
reward — each as its own adapter, each building on the last.

This document is grounded in what the underlying engine (mlx-swift-lm via the
llamero bridge) can actually do today, and lays out a phased path to the rest.

## What the engine actually supports (verified 2026-06-16)

The training engine is `MLXLLM/LoraTrain.swift` (`LoRATrain`), wrapped by the
bridge's `train_adapter`. The hard facts:

- **It trains on `[String]`.** `loadLoRAData` reads `train.jsonl` (`{"text": …}`
  per line) or `train.txt` (one example per line) into an array of strings, and
  `LoRABatchIterator` tokenizes each string and computes **full-sequence
  causal-LM loss**. There is no built-in prompt-masking; "supervised" vs
  "unsupervised" is purely *how the string was framed*.
- **No built-in RL.** There is no DPO/PPO/GRPO/reward-model code in mlx-swift-lm
  — `LoRATrain` only has the SFT cross-entropy `loss`. (Grep hits for "reward"/
  "preference" are incidental words in unrelated VLM model files.)
- **The loss function is pluggable.** `LoRATrain.train(…, loss: LoraLossFunction
  = loss, …)` takes a `(Module, inputs, targets, lengths) -> (loss, tokens)`
  closure. A custom loss (e.g. DPO) can be supplied **without** changing the
  trainer or adding rollouts.
- **Generation already exists** in the bridge (`generate`), so an online-RL loop
  (sample → reward → update) is buildable on top, it just isn't there yet.
- **Adapters can be fused** into the re-quantized base (`activate_adapters(…,
  fuse: true)`, shipped). This is the mechanism that lets training **stages
  stack**: fuse stage N's adapter into the base, then train stage N+1 on the
  now-knowledgeable base.

So the four methods sit on a feasibility gradient, all reachable from this one
engine:

| Method | Mechanism | Status |
|---|---|---|
| Unsupervised continued-pretraining | raw text strings, full-seq loss | **shipped** (`TrainingDataset.from_text` / `from_documents`) |
| Supervised fine-tuning | chat-rendered prompt/completion strings | **shipped** (`from_pairs_jsonl`) |
| Preference optimization (DPO/ORPO) | custom `LoraLossFunction` over (chosen, rejected) | reachable, medium lift (no rollouts) |
| Online RL (GRPO) | generate → reward → policy-gradient loop | buildable, large lift |

## The sequential-adapter pipeline

A model is grown through stages; each stage is a named adapter trained with one
method, and **fusing carries each stage's learning into the base for the next**:

```
base ──[unsupervised on docs]──► adapter A ──fuse──►
base+A ──[SFT on task pairs]────► adapter B ──fuse──►
base+A+B ──[preference/RL]──────► adapter C  (keep hot-swappable, or fuse)
```

Concretely, in Crystal this is already expressible today for the first two
stages, because `fuse: true` mutates the resident base and `train_adapter`
trains on whatever base is resident:

```crystal
# Stage 1 — learn the domain (unsupervised)
session.train_adapter("fsdd-domain", TrainingDataset.from_documents(doc_paths), cfg)
session.activate_adapters(stack("fsdd-domain"), fuse: true)   # bake it in

# Stage 2 — learn the task format (supervised), on the domain-aware base
session.train_adapter("fsdd-refine", TrainingDataset.from_pairs_jsonl(pairs), cfg)
session.activate_adapters(stack("fsdd-refine"), fuse: true)
# ...stage 3 (preference/RL) once those land...
```

The end artifact is either the last adapter (hot-swappable onto a base that has
the earlier stages fused in) or one fully-fused specialist. The `load_count` and
reload semantics of fused deactivation (see the local-inference skill) keep this
honest: switching away from a fused stack reloads the original base.

Open question to resolve when building Stage 3: whether to keep stages as
*separate* adapters re-applied at load (composable, but only the last is live
unless fused) or to always fuse-forward (simpler, but loses the ability to A/B a
single stage). The fuse API supports both; the pipeline helper should make the
choice explicit.

## Preference optimization (DPO) — the tractable "RL layer"

DPO needs no reward model and no rollouts: it optimizes the policy to prefer a
`chosen` completion over a `rejected` one, relative to a frozen reference
(the base). That maps cleanly onto the pluggable loss:

- **Data**: a new `TrainingDataset.from_preferences_jsonl` over
  `{"prompt", "chosen", "rejected"}` rows.
- **Bridge**: a `PreferenceBatchIterator` yielding tokenized (prompt+chosen) and
  (prompt+rejected); a `dpoLoss` closure computing
  `-log σ(β·((logπθ(chosen) − logπref(chosen)) − (logπθ(rejected) − logπref(rejected))))`.
  The reference logprobs come from the base with the adapter disabled (one extra
  forward), so no second model is needed.
- **Crystal**: `train_adapter(name, dataset, config, method: :dpo)` — a `method`
  enum on `AdapterTrainingConfig` selecting the loss; the bridge routes to the
  DPO path.

This is the recommended first "beyond-SFT" method because it is fully offline.

## Online RL (GRPO) — the larger lift, and where it shines

GRPO (group-relative policy optimization) is the simplest effective online RL:
for each prompt, sample K completions, score each with a **reward function**,
normalize advantages within the group, and do a policy-gradient update. No value
network. The pieces llamero needs:

- A training loop in the bridge that, per step, calls `generate` K times, invokes
  a reward callback, computes the GRPO objective, and updates the LoRA params.
- A **reward callback across the FFI boundary** — and this is where llamero is
  unusually well-positioned. The reward can be a **Crystal proc**, so rewards are
  *programmatic and verifiable*:
  - `BaseGrammar` parse success + field correctness (structured-output reward),
  - **does generated code compile/run?** (`crystal build` / execute and check),
  - rubric or citation checks against the source docs.

Verifiable rewards on small models are the sweet spot: the FSDD adapters already
have a natural reward (the output must be a valid feature-story JSON that passes
the schema and scope-gating), so GRPO could push correctness past what SFT alone
reaches.

Risk: small-model online RL is unstable and slow on-device; gate it behind clear
metrics and start from a strong SFT checkpoint.

## The documentation → training-data generator

This is the multiplier. Llamero already has every piece needed to turn
documentation into training data: generation (cloud `Client` for quality, or the
native track), structured output (`BaseGrammar` validation), and now the training
methods. The generator closes the loop **docs → data → adapter → better model**.

From one documentation corpus, emit data for every method:

- **Unsupervised text** — chunk the docs (`from_documents`, shipped). No model
  needed.
- **Supervised pairs** — for each doc section, prompt a model to produce
  "how do I X?" → answer / **code example**, validated by a `BaseGrammar` schema.
  For code, *verify by compiling/running* and keep only examples that pass — the
  data is then known-correct, not just plausible.
- **Preference pairs** — pair a doc-grounded correct answer (chosen) with a
  plausible-but-wrong one (rejected, e.g. an invented API name the docs don't
  contain).
- **RL rewards** — reuse the same verifiers (compiles? parses? cites a real
  symbol?) as the GRPO reward function.

The payoff for **code** specifically: code examples are *executable*, so the
generated dataset can be auto-filtered to only-correct examples and the RL reward
is objective. A library can ship a command that turns its own documentation into
a specialist adapter that has actually-correct, compile-verified knowledge of its
API — self-generating, self-verifying expertise.

## A consistent format

One JSONL schema feeds every method, so the generator emits a uniform stream and
the trainer dispatches on `kind`:

```jsonc
{"kind": "text",       "text": "..."}                                   // unsupervised
{"kind": "pair",       "prompt": "...", "completion": "..."}            // SFT
{"kind": "preference", "prompt": "...", "chosen": "...", "rejected": "..."} // DPO
{"kind": "trajectory", "prompt": "...", "reward_spec": {...}}           // RL prompt + how to score
```

`TrainingDataset` gains a `from_corpus_jsonl` that reads a mixed file and routes
each `kind` to the right method (or splits it into per-method datasets for a
staged pipeline). The generator and the trainer then speak the same language.

## Phased roadmap

- **Phase 0 — composable methods (done / in progress).** Unsupervised
  (`from_text`/`from_documents`, shipped), supervised (`from_pairs_jsonl`,
  shipped), fuse-forward stacking (shipped). Example:
  `examples/train_unsupervised_docs_adapter.cr`.
- **Phase 1 — doc→data SFT generator.** A Crystal tool: docs → candidate pairs
  via a llamero model → `BaseGrammar` validation → compile/run verification for
  code → SFT dataset. Highest immediate value, no bridge changes.
- **Phase 2 — DPO.** Preference dataset + pluggable `dpoLoss` in the bridge +
  `method: :dpo`. Fully offline, unlocks the "preference layer".
- **Phase 3 — GRPO with Crystal reward callbacks.** Generation loop in the
  bridge + a reward-proc FFI; rewards = schema/compile verifiers.
- **Phase 4 — unified `kind` format + one-shot pipeline.** `from_corpus_jsonl`
  and a "docs in → staged specialist adapter out" command tying it together.

## Honest unknowns

- DPO needs reference-logprob plumbing through the bridge (one extra forward per
  example) — straightforward but unbuilt.
- GRPO on-device is unproven in this stack; reward-callback FFI and update
  stability both need prototyping before promising it.
- "Fuse-forward" compounding re-quantization error across many stages is
  untested; measure correctness after each fused stage (the fuse work showed one
  stage preserves 4/4, but N stages is an open question).
