# Crystal-expert + agentic training corpus — plan

The aim: an **open-source filter for Gemma** that makes a small local model genuinely
useful for coding in Crystal — it writes idiomatic, version-correct Crystal, names
files/classes per convention, and (the advanced tier) **acts**: thinks, looks things
up, and emits tool calls to write the right files in the right places. The Amber
filter layers product knowledge so it answers from innate knowledge, not 50 tool
calls. Two distinct corpora, basic → advanced.

This builds on what exists: the doc→data tooling (`DocExtractor`, `ExampleGenerator`,
`crystal-training`), the `--verified` compile gate, `FSDDReward` + the
`AmberCompileJudge`, `StagedPipeline` (drift-robust guard), `TrainingFilter`
chains, and the curation fan-out. See [[honesty-aware-rl]],
[[distributable-crystal-model-vision]].

---

## Corpus 1 — the Crystal-language expert (the foundation, basic tier)

Goal: write idiomatic Crystal extremely well, knowing the stdlib and which features
exist in which version. Pure-Crystal code **compiles standalone**, so the
`--verified` gate applies fully — this corpus can be ~100% compile-gated, the
highest-quality data we can make.

### 1a. The method catalog (deterministic)
`crystal docs --format=json` on the Crystal **stdlib** emits every type, method,
signature, and doc comment. `DocExtractor` already ingests this shape. Produce:
- **Signature/behavior pairs**: "What does `Enumerable#tally` do? / signature +
  the authored doc example", straight from the JSON. No hallucination.
- **Idiomatic-usage pairs**: "How do I group-and-count in Crystal? / `arr.tally`",
  compile-verified via `ExampleGenerator`.
- **API-surface coverage**: enumerate the high-traffic types (Array, Hash, String,
  Enumerable, Iterator, Int/Float, Time, IO, File, JSON, Regex, Set, Tuple,
  NamedTuple, Channel, Process…) so the catalog is broad, not just popular methods.

### 1b. Version awareness (the harder, valuable part)
Crystal doesn't uniformly annotate `@since`. Build it from **per-version API
snapshots**: for each release tag (1.0, 1.4, …, current), check out the compiler,
run `crystal docs --format=json`, and **diff the catalogs** to learn when each
type/method first appeared (and deprecations). Output version-tagged facts:
- "Is `Slice#unsafe_slice_of` available in Crystal 1.2? / no — added in 1.x".
- "What changed for `String` between 1.6 and 1.10? / …".
This makes the model answer version questions instead of guessing, and lets a
consumer pin the filter to their toolchain version.

### 1c. Idiom + language-reference
Ingest the Crystal **language reference** (the book) for syntax/semantics prose,
and mine idiomatic patterns from the stdlib source itself. All generated examples
compile-gated. Tag by topic (blocks, generics, macros, unions, error handling,
concurrency) so coverage is auditable by a completeness critic.

### 1d. Pipeline & artifact
`crystal-training extract --shard <crystal-stdlib> --verified` + the version-diff
step + the fan-out curation (workers grounded in the catalog) → a kind-tagged
corpus → train via `StagedPipeline` (unsupervised on stdlib text → SFT on verified
pairs → GRPO with `crystal build`/`format` reward) → ship as **`crystal@x.y.filter`**
(the open-source base). The Amber filter is then one adapter trained on the
crystal-fused base (fuse-forward), per the distribution decision.

---

## Corpus 2 — the agentic tier (Q + A + THINKING + tool calls)

Explicitly **differentiated** from Corpus 1. This teaches the model to *act*, not
just answer. Three new dimensions:

### 2a. Q + A + thinking
- **Thinking models**: train completions with an explicit reasoning trace — a
  `<thinking>`/scratchpad block that we *author to model the habits we want*:
  restate the task → identify the FSDD layer/artifact → decompose into named steps
  → recall the relevant Crystal/Amber API (or admit it's unknown) → plan the
  file/class/method names → then the answer. We train the *shape of the thought*,
  not just the answer.
- **Non-thinking models (Gemma base)**: bake the decomposition into the visible
  response as a short plan-then-act preamble — "This needs a process manager
  `Billing::LockAccount` with `perform` calling `validate`, `lock`, `notify`; file
  at `src/billing/lock_account.cr`. Now the code:" — then the code. Longer,
  structured turns that make the reasoning legible and trainable.
- The thinking content **encodes the good habits**: decompose first, don't get lost
  in the weeds (stay at one FSDD layer), verify/admit gaps (the honesty behavior we
  already reward), pick the convention-correct names. This is the "corralling"
  the owner described — teaching it *how to think through a problem* like a kid.

### 2b. Tool-call training (act: write the right file in the right place)
Not just "output Crystal" — output a **tool call** that writes the file. Concretely:
- Define a small tool surface the harness executes: `write_file(path, content)`,
  `read_file(path)`, `look_up(query)` (docs/grep), `run(cmd)` (build/spec).
- Gemma has no native tool-calling, so we train a **fixed output format** (e.g.
  `<tool_call>{"name":"write_file","path":"src/billing/lock_account.cr","content":"…"}</tool_call>`)
  the harness parses. (If the chosen base has a tool template, use it.)
- Training pairs: technical feature story → [optional thinking] → the `write_file`
  call(s) with **AED-correct path** (snake_case file, namespace→folder,
  `src/controllers/…_controller.cr`, etc.) + **AED-structured content**.
- The path-naming is itself a gradable convention (we already encode the AED file
  rules); the content is graded by the compile judge + `FSDDReward`.

### 2c. Self-lookup
Train the model that when it's unsure of an API, the move is **look it up**, not
fabricate: emit a `look_up("Array#…")` / `run("crystal docs")` tool call (or, when
no tool is available, the honest typed stub that names what to verify — which we
already train). This is the bridge between the honesty floor and agency: "admit
the gap" graduates into "admit the gap *and* go find the answer."

---

## The 4B → 1B delegation architecture (the goal)

- **4B = planner.** Input: a feature story / ask. Output: a *technical feature
  story* (FSDD layer-3 artifact) + a delegation manifest (which files/classes the
  implementer must create). Trained for decomposition + correct FSDD structuring.
- **1B = implementer/actor.** Input: the technical feature story + one task. Output:
  [thinking] + `write_file` tool calls following AED — correct file path, class
  name, typed signatures, idiomatic Crystal, stock-Crystal tool use; honest stubs
  where it doesn't know.
- This is **part harness, part training**: llamero's `ModelPool` keeps both models
  resident; the 4B's structured output (a `BaseGrammar` technical-story schema)
  feeds the 1B. We train each model for its role; the harness orchestrates the
  hand-off and the loop (the "corral").
- Filters compose here: the 1B runs `crystal@x.y` (+ `amber` for product work); the
  4B can run a planning filter. The agentic corpus trains the 1B's act behavior on
  top of the crystal/amber knowledge.

---

## Layered filters: ordering & count (the honest answer + the experiment)

The owner asked: can we layer up to ~10 filters, and does **order** change the
leaning (amber-first vs crystal-first)?

**Today:** the bridge supports **one live adapter** (it rejects multi-stacks,
`Bridge.swift:731`) or **fuse-forward** composition. "10 layered filters at
runtime" is not supported yet.

**The math matters for the intuition:** runtime LoRA stacking is *additive* —
`W' = W + Σ scaleᵢ·BᵢAᵢ`. Addition is **commutative**, so amber-then-crystal and
crystal-then-amber produce the **same** weights → **order does not change the
output** for pure additive stacking. The "leaning" you're picturing comes from two
*other* levers:
1. **Scale/weight** per adapter (`scaleᵢ`) — weighting amber higher *does* bias
   toward amber. That's the real knob for "more amber influence" (not order). The
   bridge also rejects non-1.0 scales today.
2. **Fuse-forward order** (train-time, non-commutative) — `crystal → amber` (amber
   trained on a crystal-aware base) genuinely differs from `amber → crystal`. This
   is where order legitimately changes behavior, and it's the production path.

**The experiment to settle it** (Phase-C runtime-stacking research, now well
motivated): lift the bridge single-adapter limit to load N live adapters + honor
per-slot scales, then measure, for N = 2..5: (a) coherence vs N (does it degrade?),
(b) **order effect** (predict ≈ none for additive — a clean confirmation), (c)
**scale effect** (the actual leaning knob — sweep amber:crystal weight), (d)
memory + tokens/sec cost (each live adapter adds LoRA compute every layer; fusing
removes it). Decision criterion as before: adopt runtime stacking only if it stays
coherent for the N we care about and beats the re-fuse cost. (N-stage *fuse-forward*
already hits the re-quant drift cliff past ~3 on 4-bit — see
`adapter_composition_experiments.md` — so deep stacks favor a bigger/higher-precision
base regardless.)

---

## RL with real test applications (the agentic RL phase)

Per-snippet rewards (`FSDDReward` + compile judge) are tier-1. The next level:
**end-to-end task RL**. The environment:
1. Start from a scaffolded Amber app (the compile-judge harness, extended to a full
   `amber new`-style project).
2. Give the model a feature story; it emits `write_file`/`run` tool calls.
3. The harness **applies** them, then **compiles the whole app** and **runs its
   specs**.
4. Reward = compiles (0 errors/warnings) + specs pass + files in AED-correct paths +
   tool-use correctness (did it write where it said?) + the FSDD conventions.

This judges *how the model uses tools* in real scenarios, and — as the owner noted
— surfaces exactly where the training/knowledge is wrong (a failing generated app
is a labeled gap). It's the natural home for GRPO once single-snippet honesty is
solid, and it's where the 4B→1B delegation gets exercised for real.

---

## Phasing (each phase ships something runnable)
1. **Crystal method catalog** — `crystal docs` JSON → verified pairs (Corpus 1a). ▶ start here; fully deterministic + compile-gated.
2. **Version-diff** — per-tag API snapshots → version-tagged facts (1b).
3. **Crystal base filter** — train + ship `crystal@x.y.filter` (open-source).
4. **Agentic corpus** — thinking + tool-call format, differentiated dataset (Corpus 2).
5. **Delegation harness** — 4B planner → 1B actor via ModelPool + schemas.
6. **Layered-stacking experiment** — lift the bridge limit; measure order/scale/N.
7. **End-to-end task RL** — generate+compile+test whole apps; reward tool use.

## Open decisions for the owner
- Tool-call output format (custom `<tool_call>` JSON vs a base-model template)?
- Thinking format: separate `<thinking>` block vs an inline plan preamble (depends
  on whether we target a thinking-capable base or stay on Gemma)?
- Which Crystal versions to snapshot for the version-diff (e.g. 1.0, 1.6, 1.10,
  1.14, current)?
- Is the open-source `crystal` filter pinned per Crystal version (one filter per
  toolchain) or version-aware-in-one?
