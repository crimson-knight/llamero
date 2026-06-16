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

## Shipped: a working RL cycle (expert iteration / rejection sampling)

The first RL method is **shipped and validated**, and it needs no policy-gradient
code — it runs on the existing SFT engine. It is genuine reward-driven policy
improvement (RAFT / ReST / expert iteration): the model practices, is judged,
learns from its best attempts, and generalizes.

- **`Reward` / `Rubric`** (`src/native/rl.cr`): composable graded checks. The
  built-in **static-analysis rewards** are the objective, verifiable signal the
  owner asked for — `CrystalCompileReward` ("no errors", `crystal build
  --no-codegen`) and `CrystalFormatReward` ("no changes made", `crystal tool
  format --check`). `FunctionReward` covers anything else (schema parse, etc.).
- **`PracticeLoop`**: per round — (1) sample K completions for each *training*
  prompt, (2) score each with the rubric, (3) keep the best per prompt that
  clears a threshold, (4) SFT the adapter on the accumulated best, (5) measure
  the greedy rubric score on a **held-out** prompt set the model never trains on.
  An optional `seed` (e.g. a few `ExampleGenerator` outputs) warms the buffer so
  there is a format to refine.
- **Validated on-device** (`examples/rl_practice_cycle.cr`, gemma-3-1b, task =
  write a Crystal `record` for an unseen spec): held-out score **0.3 → 1.0** in
  one round, both objectives perfect (`compiles` 0.4→1.0, `format-clean`
  0.2→1.0), and `kept` rising 3→7 as the loop graduates from seeds to the
  model's own passing attempts. The improvement is on **specs never trained on**
  — real generalization, not memorization.

This is the practical RL layer. GRPO below is the heavier upgrade for when
per-token credit assignment (not just best-of-N) is needed.

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

- **Phase 0 — composable methods (done).** Unsupervised
  (`from_text`/`from_documents`, shipped), supervised (`from_pairs_jsonl`,
  shipped), fuse-forward stacking (shipped). Example:
  `examples/train_unsupervised_docs_adapter.cr`.
- **Phase 1 — doc→data generator (shipped, deterministic).** Rather than have a
  model invent examples (and then filter the invalid ones), Phase 1 is
  **deterministic and valid-by-construction** — no model in the loop:
  - **`Llamero::Native::DocExtractor`** pulls the *authored* code examples out of
    real docs with their context. From Crystal API docs it walks the
    `crystal docs --format=json` tree (`program.types[]`, recursive) and reads
    the raw-markdown `doc` on every type and member, extracting fenced code
    blocks tagged with the symbol's signature. From standalone markdown pages
    (e.g. an Amber controller guide) it pairs each fenced block with its heading
    and preceding prose. Output: `to_supervised_dataset` / `to_unsupervised_dataset`
    or a kind-tagged JSONL corpus.
  - **`Llamero::Native::ExampleGenerator`** mixes and matches documented chunks
    into the **full breadth of valid variations** (a template with `slot`s and a
    `combo` that enumerates subsets of chunks), pruned by `constrain` and
    confirmed by `verified` (compile-checks each via `crystal build`). Every
    combination is valid by construction; we only generate valid examples.
  - Proven end-to-end: `examples/generate_training_from_docs.cr` extracts the
    Amber guide and generates 28 controller variations, **28/28 compile-verified**.
    The LLM-assisted variant (a model proposes pairs, `BaseGrammar` + compile
    verify gate them) remains a *future* option for prose-heavy docs where
    authored examples are sparse — but the deterministic path is the default.
- **Phase 2 — RL via expert iteration (shipped).** `Reward`/`Rubric`/
  `PracticeLoop` with static-analysis rewards (compile + format-clean). Validated
  on-device: held-out 0.3→1.0. No bridge changes — runs on the SFT engine.
- **Phase 2.5 — `from_corpus_jsonl` (shipped).** Loads the kind-tagged corpus
  (text/pair) into a trainable dataset, closing docs→data→train.
- **Phase 3 — DPO (shipped).** `PreferenceDataset` {prompt,chosen,rejected} +
  `RLTrain.runDPO` in the bridge (cache frozen-base reference logprobs, then the
  DPO loss over chosen/rejected). `train_adapter` selects `method: :dpo`.
  Validated on-device (record task): preference margin -0.003→7.26, held-out
  rubric 0.25→0.375 with early stop + high `dpo_beta`. Over-optimizes at high
  iters/low beta (faithful to real DPO) — keep beta high and stop early.
- **Phase 4 — GRPO (shipped, two ways).** `RLTrain.runWeighted` is an
  advantage-weighted completion-logprob update with a **per-token KL-to-reference
  anchor** (DeepSeek k3, references cached from the frozen base before LoRA) — the
  anchor makes multi-round GRPO **rock-solid**: the accumulating config that
  collapsed 0.5→0.1→0.0 without it now holds stable across rounds.
  - *Crystal-orchestrated* (`WeightedDataset` + `train_adapter`): Crystal samples,
    scores, computes advantages, calls the weighted update. Validated 0.0→0.3→0.2.
  - *Bridge-driven* (`session.grpo_train`, `llamero_mlx_session_grpo_loop`): the
    BRIDGE runs the whole loop — generate → **reward via a reward-callback FFI**
    (serviced on the Crystal thread by `drainRL`) → advantage → KL update, for N
    rounds. Validated on-device: 48 reward callbacks, per-round mean reward
    0.167→0.458, held-out 0.0→0.167, no deadlock. This is the "bridge drives the
    loop, Crystal only supplies the reward" architecture.
- **Phase 5 — one-shot pipeline.** "docs in → staged specialist adapter out"
  tying extractor → generator → unsupervised → SFT → expert-iteration/DPO/GRPO.

## Honest unknowns

- DPO needs reference-logprob plumbing through the bridge (one extra forward per
  example) — straightforward but unbuilt.
- GRPO on-device is unproven in this stack; reward-callback FFI and update
  stability both need prototyping before promising it.
- "Fuse-forward" compounding re-quantization error across many stages is
  untested; measure correctness after each fused stage (the fuse work showed one
  stage preserves 4/4, but N stages is an open question).
