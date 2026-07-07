# GBNF grammar-constrained generation — measured results

Date: 2026-07-07 (v2, post-audit). All numbers are our own measurements from this
harness (`src/bench.cr`). The **entire dataset was regenerated in one session on
the UTF-8-fixed llamero build** (`5648de9` lineage; see finding 6) — no rows
predate the fix. Raw per-run data INCLUDING the full raw text of every attempt
is checked in at `results/runs.jsonl` (`attempt_log[].content`); live log in
`results/bench_run.log`; per-field re-scoring script `analyze_fields.py`.
Nothing here is copied from any prior claim.

## Vocabulary — read this first

- **"Oracle pass" is NOT "fully correct."** The oracle checks a calibrated
  SUBSET of fields per task (deviation 3 below): flat checks 4 of 5 declared
  fields; medium checks 4 predicates; cliff checks 3 top-level fields only.
  Every "pass/success" figure in this document means "passed the calibrated
  partial oracle," and per-field results are reported so you can re-score.
  Stricter key-presence scoring only hurts unconstrained arms; strict
  value-fidelity scoring hurts every arm at this model scale (details in
  deviation 3 and Threats).
- **"temp0" cells**: attempt 1 at temp 0; retry attempts (which in practice only
  unconstrained arms needed) resample at temp 0.8 with a fresh seed. Cliff-task
  unconstrained passes are therefore mostly temp-0.8-retry passes, not greedy
  passes (first-attempt oracle fail rate was 100% there).

## Environment

- Apple M1 Max, 32 GiB, macOS 26.5, mains power. One machine, one session.
- Inference: pinned llama.cpp `b9902` @ `55edb2de442b50be0a29c2ed2ec88488560a96c5`,
  CPU-only static `llama-completion` built by llamero's installer. The harness
  asserts the fail-closed probe **before any timing** (~20-30 ms, excluded).
  The probe consults only `$LLAMERO_HOME/llamacpp/b9902/bin` — never PATH — so
  no other llama.cpp install on this machine can influence these numbers.
- Library: llamero branch `gbnf-structured-generation` (UTF-8 scrub fix
  included); grammar arms run the real product path
  `CompletionBackend#chat_structured(generation_mode: :grammar)`.
- Crystal 1.20.0 (stock), harness built `--release`.
- Identical across arms: ctx 2048, threads 4, **max_tokens 400**, prompts,
  retry policy, parsing leniency.

## Models (matched lineage)

- **base**: SmolLM-135M-Instruct, f16 GGUF dequantized from
  `mlx-community/SmolLM-135M-Instruct-4bit` — deliberately the same checkpoint
  lineage the tuned model descends from (no precision/conversion asymmetry).
- **tuned**: same checkpoint + LoRA (rank 8, 300 iters, lr 1e-4), fused,
  identical f16 GGUF pipeline.

**What "tuned" honestly is:** a llamero-docs Q&A knowledge pack (short factual
chat answers), **not trained on these tasks or on JSON emission**. Tuned arms
measure composition with an *incidental* adapter. Where the tuned model is
fast, the visible mechanism is learned brevity/EOS discipline, not extraction
skill.

## Protocol

4 arms x 3 tasks x N=25 = 300 runs (plus every failed attempt's raw output).

- **Arms**: {base, tuned} x {unconstrained, grammar}. Unconstrained = plain
  completion + the product's own lenient JSON extraction + typed parse.
  Grammar = `generation_mode: :grammar` with `grammar_parse_retries: 0` so the
  harness owns all retry accounting identically.
- **Matched prompts**: byte-identical message lists per task (system message
  naming keys + one few-shot pair + task text). Only delta: `--grammar-file`.
- **Wall-to-pass**: clock accumulates across attempts (max 3) until the oracle
  passes; retries bill to the failing arm.
- **Fair clock**: every attempt in every arm spawns a fresh subprocess and pays
  full model load (~43 ms) in its wall time; grammar tempfile write is on the
  grammar clock.
- **Tasks** (`src/schemas.cr`): flat (5 required scalars), medium (nested
  object + array), cliff (depth-5, exactly 6 optionals = the budget boundary,
  2^6=64-variant subset alternation, 24,339-byte grammar).

### Documented deviations from the spec protocol

1. **N=25 per cell, not >=50.** Honest scope: medians of the deterministic
   first-attempt cells are tight (IQR within a few % of the median), but
   retry-heavy cells are NOT (cliff base-unconstrained IQR 4,045–5,634 ms), and
   p90s everywhere are coarse at N=25. Treat pass rates and medians as the
   findings; treat tails as indicative only. Rerun with `BENCH_N=50` to tighten.
2. **Prompt calibration**: the spec draft's verbatim-schema instruction made
   ALL FOUR arms 0-for-4 in the smoke run
   (`results/smoke_schemadump.jsonl`): a 135M model needs a worked example. Both
   arms got the identical few-shot prompt, changed simultaneously, before any
   headline run.
3. **Partial oracles, calibrated on smoke runs** (equally for every arm):
   flat drops `currency` (every arm copies the few-shot example's currency —
   subtracting a constant from all four arms); cliff checks `id`/`severity`/
   `title` only (every arm hallucinates depth-3+ values; checking them zeroes
   all arms). Medium's load-bearing predicate is the exact `email` string.
   **The raw text of every attempt is now checked in**, and
   `analyze_fields.py` re-scores per field; under the *weakest* structural
   oracle ("all declared keys present") unconstrained medium goes to 0/25 as
   well, because `email` appeared in **0 of 106 parseable** unconstrained
   medium JSON emissions (one malformed, non-parseable retry attempt did
   contain the string — see Results). Scoring strictness cuts two ways:
   stricter *key-presence* scoring only lowers unconstrained arms (grammar
   arms have every key by construction), but a full *value-fidelity* oracle
   lowers arms across the board at 135M — e.g. tuned-grammar medium emits
   `"city": "Berlage"` (garbled Berlin) in 25/25 runs while passing our
   oracle. Grammar guarantees structure, never value correctness.
4. **Retries are temp 0.8 + fresh seed**, not temp 0 (greedy retries can never
   change the outcome). Consequence: see Vocabulary on "temp0" cells.
5. `ws` in generated grammars is bounded (`{0,20}`), not `*` (documented in the
   llamero README; unbounded ws let the constrained base model emit whitespace
   forever).

## Results

Table columns: "oracle pass rate" per Vocabulary; wall/IQR/p90 computed over
**passing runs only** (so cells with <25/25 passes are survivor-conditioned and
NOT comparable across arms — flagged inline).

### Task: flat

| arm | N | oracle pass | median wall-to-pass (ms) | IQR (ms) | p90 (ms) | median tokens | first-attempt fail | median attempts | sampler us/token |
|---|---|---|---|---|---|---|---|---|---|
| base-unconstrained | 25 | 25/25 | 2,083 | 2,009–2,136 | 2,420 | 399 | 0% | 1 | 16.3 |
| base-grammar | 25 | 25/25 | 460 | 454–465 | 471 | 54 | 0% | 1 | 5.3 |
| tuned-unconstrained | 25 | 25/25 | 451 | 444–455 | 458 | 54 | 0% | 1 | 5.1 |
| tuned-grammar | 25 | 25/25 | 451 | 446–457 | 473 | 54 | 0% | 1 | 5.2 |

### Task: medium

| arm | N | oracle pass | median wall-to-pass (ms) | IQR (ms) | p90 (ms) | median tokens | first-attempt fail | median attempts | sampler us/token |
|---|---|---|---|---|---|---|---|---|---|
| base-unconstrained | 25 | **0/25** | n/a | n/a | n/a | 1197 | 100% | 3 | 15.1 |
| base-grammar | 25 | 25/25 | 527 | 520–538 | 542 | 63 | 0% | 1 | 5.8 |
| tuned-unconstrained | 25 | **0/25** | n/a | n/a | n/a | 165 | 100% | 3 | 4.6 |
| tuned-grammar | 25 | 25/25 | 522 | 501–583 | 881 | 64 | 0% | 1 | 5.7 |

Per-field audit of what unconstrained arms actually emitted (all *parseable*
attempts — raw-JSON parse failures among temp-0.8 retries are excluded and
counted separately: 21/75 base, 23/75 tuned; `analyze_fields.py` on the
checked-in raw text):

| medium, unconstrained | base (54 parsed emissions) | tuned (52 parsed emissions) |
|---|---|---|
| `name` key present | 53 | 52 |
| `age` key present | 53 | 50 |
| **`email` key present** | **0** | **0** |
| `address` key present | 7 | 43 |
| `tags` key present | 53 | 43 |

Among parseable emissions the failure is structural omission, not syntax: the
JSON parses, but the `email` key was absent from every one of the 106
parseable unconstrained emissions (the typed parse then defaults it); the
only retry attempts containing an email string were themselves malformed
JSON. First attempts all parsed — the parse failures above are temp-0.8
retries. The grammar makes the key mandatory; both models then filled it with
the correct email from the text, 25/25 each. Any oracle requiring all
declared keys — not just ours — scores unconstrained medium 0.

### Task: cliff (near-budget type: depth 5, 6 optionals, 24 KB grammar)

| arm | N | oracle pass | median wall-to-pass (ms) | IQR (ms) | p90 (ms) | median tokens | first-attempt fail | median attempts | sampler us/token |
|---|---|---|---|---|---|---|---|---|---|
| base-unconstrained | 25 | 16/25 | 4,073 (survivors only) | 4,045–5,634 | 6,131 | 798 | 100% | 3 | 11.2 |
| base-grammar | 25 | 25/25 | 842 | 825–852 | 859 | 116 | 0% | 1 | 5.1 |
| tuned-unconstrained | 25 | 5/25 | 1,078 (survivors only) | 974–1,311 | 1,380 | 103 | 100% | 3 | 1.6 |
| tuned-grammar | 25 | 25/25 | 975 | 960–989 | 997 | 136 | 0% | 1 | 5.9 |

Cliff unconstrained "passes" are all retry passes at temp 0.8 (first-attempt
fail 100% in both unconstrained arms); their medians are conditioned on the
surviving 16/25 and 5/25 subsets and are **not comparable** to the grammar
arms' 25/25 medians.

### Headline deltas (quoted ONLY where both arms pass 25/25)

- flat / base: unconstrained 2,083 ms → grammar 460 ms (**78% lower median
  wall-to-pass**, both 25/25) — see finding 2 for what this really measures.
- flat / tuned: 451 ms → 451 ms (**0%**) — grammar adds nothing when the model
  already stops and formats correctly.
- medium (both models) and cliff (both models): **not comparable on time**;
  the result is the pass rate: grammar 25/25 everywhere vs 0/25, 0/25, 16/25,
  5/25.

## Findings

1. **Grammar's dominant measured win at this scale is structural correctness.**
   Unconstrained 135M output usually parses but is incomplete or wrong
   (medium: 0/50 oracle passes across both models, email key in 0/106 parseable
   emissions; cliff: 100% first-attempt oracle fails everywhere). Grammar arms
   passed the calibrated oracle on the first attempt in 150/150 runs. (Not a
   claim of full semantic correctness — see Vocabulary.)
2. **The flat-task speed win is real but is mostly a no-stop artifact.** An
   unconstrained base 135M never emits EOS and rambles to max_tokens (399
   tokens for a 54-token answer); the grammar terminates at the closing brace.
   The 78% delta is honestly stated as: *grammar vs an unconstrained baseline
   with no stop heuristic at max_tokens 400.* A production stop-sequence hack
   would narrow this specific gap (we did not benchmark such a baseline); it
   would not fix medium/cliff structural failures.
3. **Composition (grammar x knowledge-pack adapter), one data point:** the
   adapter already fixed rambling (tuned-unconstrained flat 451 ms = grammar
   speed), so grammar cost nothing on flat (451 vs 451 ms) — and the adapter
   alone could not produce structurally complete records (medium 0/25, cliff
   5/25), which grammar-on-tuned restored to 25/25. Latency composition is
   task-dependent: tuned-grammar matched base-grammar on flat/medium but was
   ~16% slower on cliff (975 vs 842 ms). No grammar-on-tuned run failed the
   oracle or showed constraint-vs-adapter conflict in its raw output, for THIS
   adapter (which is unrelated to the task), THIS model family, N=25. A
   composition data point, not a law.
4. **Grammar-size scaling, measured within budget:** 495 B → 619 B → 24,339 B
   grammars produced no sampler-cost growth (5.3 → 5.8 → 5.1–5.9 us/token) on
   the pinned CPU build, 49k vocab. The budget's boundary case is usable at
   this scale. **We did not measure past-budget decoding** — the budget refuses
   it by design; the cliff-existence rationale (llama.cpp
   `MAX_REPETITION_THRESHOLD`, JSONSchemaBench coverage drops) is external
   literature, not our measurement.
5. **Past the budget it refuses at compile time**: the 7th optional on
   `CliffBreaker` fails `crystal build` with the reason
   (`results/cliff_compile_refusal.txt`); `:auto` falls back to schema-prompt
   with `gbnf_fallback_reason` (branch spec suite).
6. **This benchmark found and fixed a real product crash.** Unconstrained
   SmolLM at retry temperature emitted invalid UTF-8 (truncated multi-byte
   codepoint at the token limit) and PCRE2 raised from output post-processing,
   killing an early run. Fixed on the branch (`String#scrub` at the subprocess
   boundary, commit `a165274`) with a regression spec, and **all 300 rows in
   runs.jsonl were regenerated after the fix in a single session**
   (`results/bench_run.log` is the uninterrupted transcript; the pre-fix
   partial dataset is archived under `results/archive_pre_audit/`, not used).

## Comparison with the owner's prior (context, not our claim)

The owner's earlier benchmarks (different setup, not reproduced here) showed
grammar cutting time-to-correct 20–30% on a base model. Our 135M measurements
do not reproduce that magnitude: bigger where the base model rambles (78% on
flat, plus not-comparable-because-unconstrained-fails elsewhere), zero where a
tune already taught stopping. We publish only our numbers; his figure is his.
The prior's other half — grammar-from-types "falls on its face" for deeply
complex types — is something we designed around (compile-time budget +
refusal), not something we measured past the boundary.

## Threats to validity (read before quoting)

- **Partial oracles.** All "pass" figures are field-subset oracles (deviation
  3). Raw outputs are checked in for re-scoring. Stricter *key-presence*
  scoring lowers unconstrained arms further (email in 0/106 parseable
  emissions) and cannot lower grammar arms (keys are grammatically mandatory);
  a full *value-fidelity* oracle lowers arms across the board at this model
  scale (tuned-grammar medium's `"Berlage"` city, every arm's copied currency
  on flat, every arm's hallucinated depth-3 values on cliff). Grammar
  guarantees structure, not values — none of our claims should be read
  otherwise.
- **One model family at one tiny scale (135M), one machine, CPU-only, one
  session.** Correctness gaps should shrink with model size; nothing here says
  a 7B behaves this way. No cross-machine replication.
- **The flat speed delta is max_tokens/stop-policy dependent** (finding 2).
- **Composition is one adapter** (rank-8, off-task) — finding 3's scope.
- **N=25**: tails coarse, retry-cell IQRs wide (deviation 1).
- **Retry-pass temps**: unconstrained cliff passes happened at temp 0.8, so
  the "temp0" label applies to first attempts only (Vocabulary).
- Perf fields other than `gen_tokens_total`/`wall_ms` in the top-level record
  are last-attempt-only; per-attempt figures live in `attempt_log[]`.
