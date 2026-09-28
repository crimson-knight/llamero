# Amber v2 grounded corpus — how it was built

The corpus here was curated by the Phase A agent fan-out, not hand-written and
not pulled from the model's prior (Amber-v1 / Rails) memory.

## Files
- `amber_v2_pairs.jsonl` — 190 grounded instruction→code pairs across 10 Amber v2
  DSL topics (routing, controllers, schema-dsl, controller-schema, websockets,
  pipes, validators, jobs, mailer, grant-models).
- `amber_v2_provenance.jsonl` — same pairs with `topic`, `source_symbol`,
  `source_file` for traceability.
- `amber_v2_sft.jsonl` — 212 deduped pairs (the 190 above + 22 doc-extracted
  Grant pairs). This is the consolidated SFT corpus; point training at it.
- `grant_pairs.jsonl` — 22 Grant ORM pairs extracted from the real Grant docs.

## Process
1. **Fan-out (round 1):** 10 Sonnet workers, one per topic, each READ the real
   `amber 2.0.0-dev` source files for its topic and emitted pairs that cite the
   v2 symbol they use. Workers were instructed not to trust prior Amber/Rails
   memory and to grep the source to confirm any API.
2. **Deterministic grounding gate:** every pair's `source_symbol` must appear
   (word-boundary) in the real `.cr` source (`amber/src` + `grant/src`) or the
   Grant usage guide — NOT the ActiveRecord comparison docs (those mention
   Rails-only APIs). Dropped `CSRF.token_strategy` (absent from source).
3. **Completeness critic:** reviewed coverage + spot-checked against source. It
   correctly caught three *calling-convention* errors that a symbol-grep gate
   can't (the symbols exist, the usage was wrong):
   - `default_scope ->{ }` should be a block `default_scope { }`;
   - `validates_if(->(ctx){})` should take a bare expression, not a proc literal;
   - `controllers` was over-concentrated (10/18 pairs on `before_action`).
4. **Corrective round 2:** re-ran the 3 flagged topics with the exact fixes and a
   wider symbol list (controllers now span redirect_to/render/respond_with/json/
   route_path/params/session/flash/cookies; grant adds transactions, nested
   attributes, generates_token_for; schema fixes validates_if + all FormatType
   values). The two surviving `->` occurrences are deliberate *contrastive*
   teaching pairs that show the wrong form labelled WRONG next to the correct one.

## A verification lesson
The critic suspected `7.days.ago` was a Rails-ism — but `crystal build
--no-codegen` confirms it IS valid Crystal (stdlib `Int#days` → `Time::Span#ago`).
The compiler is the arbiter; we did not filter it. Crystal shares enough surface
with Ruby that "looks like Rails" is not sufficient grounds to drop a pair.

## Re-running
The fan-out workflow scripts are saved under
`.claude/.../workflows/scripts/amber-v2-curation*.js` and are re-runnable for
more rounds (drive the next round from the critic's `coverage_gaps`). The
grounding-gate/merge script used was `/tmp/merge_curation.py`.

## Round 3: Grant tenancy/raw SQL/parity (2026-09-24)

### Scope and source ledger

Round 3 adds 84 pairs to the 212-row Amber V2 corpus. The regenerated
`amber_v2_sft.jsonl` has 296 rows: `row_tenancy` 14, `schema_tenancy` 14,
`amber_tenant_pipe` 14, `apartment_migration` 14, `raw_sql` 20, and `parity` 8.
The pair and provenance files are `grant_tenancy_rawsql_pairs.jsonl` and
`grant_tenancy_rawsql_provenance.jsonl`; `rebuild_amber_v2_sft.py` recreates the
combined corpus from the preserved earlier rows and the new pairs.

Grant evidence was read from `grant-integration` commit
`c6b5e72c1e2663fe6b5cb6794a5beddd0c34f7a3` (branch
`fix/tenancy-and-parity`) and the named Grant guide snapshot at
`fd988199a97a360f96b0cb06bac36c28085958c7`. Amber handler examples were checked
against Amber commit `f2a1490fc7d25310a8d08cca8fe15434ec08169f`. The code does
not use Rails or ActiveRecord as evidence. The 41 distinct Grant provenance
anchors are:

`Grant.connection`, `Grant::Migrator`, `Grant::Result`,
`Grant::SchemaTenant.with`, `Grant::Tenant.with`, `HABTM`,
`InvalidSchemaNameError`, `Migration CLI`, `Model.connection`, `NoTenantError`,
`Row-level multi-tenancy`, `ScopedRawSqlError`, `TenantMismatchError`,
`UnsupportedSchemaTenantAdapterError`, `belongs_to`, `count_by_sql`,
`create_schema`, `create_tables`, `current_schema`, `drop_schema`, `exec`,
`exec_query`, `execute`, `find_by_sql`, `find_each`, `includes`, `list_schemas`,
`multitenant`, `public.`, `query cache`, `sanitize_sql_array`, `scalar`,
`schema-per-tenant switching`, `schema_tenant_excluded`, `select_all`,
`select_one`, `select_rows`, `select_value`, `select_values`, `unscoped`, and
`where.has`. Additional Grant-qualified types appearing in completions are
`Grant::Adapter::Pg`, `Grant::Base`, `Grant::InvalidSchemaNameError`,
`Grant::Migrator`, `Grant::NoTenantError`,
`Grant::Querying::ScopedRawSqlError`, `Grant::Result`, `Grant::SchemaTenant`,
`Grant::Tenant`, `Grant::TenantMismatchError`, and
`Grant::UnsupportedSchemaTenantAdapterError`.

### Review and deterministic gates

- The source-symbol gate passed 84/84 rows with word-boundary matches in the
  cited, pinned Grant or Amber source and the allowed guides. All 84 provenance
  rows align with one pair, and the completion coverage check passed 84/84.
- `crystal-alpha build --no-codegen` compiled all 84 completions against the
  pinned Grant snapshot; 0 warnings, GREEN. Complete class/program definitions
  were checked directly and executable fragments were checked in generated
  harnesses. The code-content inspection found 74/84 class/program definitions
  (88.1%); the other 10 are executable top-level Crystal calls or query
  expressions, not prose fragments.
- Formatter check passed. The American-English word-boundary scan found 0
  violations. Exact and near-duplicate checks found 0 overlaps with the earlier
  212 rows; those earlier rows remain unchanged and in order in the regenerated
  corpus, for 296 rows total.
- Read-the-rows check printed 3 verbatim rows for each of the 6 topics (18/18).
  Negative probes confirmed the gate rejects an invalid source symbol and an
  uncompilable completion.
- The Crystal conventions and AED naming critic was applied to code the model
  will imitate. Review findings were fixed by replacing generic wrappers with
  direct API calls or process-shaped examples, tightening AED names, and making
  nil handling explicit. No unresolved MAJOR rubric findings remain.
- The evaluator confirmed the 20 Grant holdout questions do not overlap the
  296 training questions. It also runs the five existing Amber regression
  questions. `grant_tenancy_eval.jsonl` contains the separate 20-question Grant
  holdout.

### Training artifact

The new filter is `~/.llamero/filters/amber-v2-0.2.0.filter`; the installed
`~/.llamero/filters/amber-v2.filter` (0.1.0) was not modified. The 0.2.0
manifest uses pinned base
`mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2`,
rank 8, scale 1.0, 16 layers, learning rate 0.0001, batch size 1, 200
unsupervised iterations, and 400 supervised iterations. The manifest and
SHA-256 inventory are preserved beside the evaluations as
`eval_results/amber-v2-0.2.0-manifest.json` and
`eval_results/amber-v2-0.2.0-sha256.json`.

The first training attempt trapped because the pinned upstream
`LoRATrain.loss` force-casts a loaded module to `LLMModel`, while Gemma 3 is a
VLM. `Bridge.swift` now uses a Gemma3-specific forward pass and causal-token
cross-entropy loss for that model and retains the upstream loss for text-only
models. The successful two-stage run emitted warnings that some sequences
exceeded 2048 tokens. Swift compilation succeeded; Xcode also printed a
destination warning and four upstream Metal C++17-extension warnings.

### Before and after evaluation

The evaluation artifacts save each raw answer, compiler result, and required
symbol result in `eval_results/grant_tenancy_before.jsonl` and
`eval_results/grant_tenancy_after.jsonl`. Before training, direct activation of
the installed 0.1.0 filter failed because its adapter keys use `model.layers.*`
while the pinned Gemma 3 VLM exposes `language_model.model.layers.*`. The
baseline below therefore uses a hash-verified scratch copy with only that key
prefix remapped; the installed 0.1.0 package remains unchanged. The after run
loaded the new 0.2.0 filter directly.

| Holdout | 0.1.0 compile | 0.1.0 symbols complete | 0.2.0 compile | 0.2.0 symbols complete |
| --- | ---: | ---: | ---: | ---: |
| Grant (20) | 2/20 (10%) | 0/20 (0%) | 2/20 (10%) | 1/20 (5%) |
| Amber regression (5) | 1/5 (20%) | 1/5 (20%) | 0/5 (0%) | 0/5 (0%) |
| Combined (25) | 3/25 (12%) | 1/25 (4%) | 2/25 (8%) | 1/25 (4%) |

Required-symbol hits were 6/61 for Grant and 9/16 for Amber before training;
after training they were 9/61 for Grant and 7/16 for Amber. The new filter
regressed on both Amber compile rate and Amber required-symbol completeness, so
do not propose 0.2.0 as the default. The held-out evaluator measures code
compilation and required-symbol coverage; it does not run these snippets
against a live database or prove runtime tenancy isolation.

The final `dep-pin-audit precommit` passed. A repository-wide dependency scan
still reports 17 findings (12 critical, 3 high, and 2 medium) in existing
workflow/audio dependency declarations and version-range metadata; the exact
Crystal lock checksums and pinned SwiftPM resolution used for this round were
verified. Those broader findings were not changed in this corpus round.

### Round 3b: adapter application and fit diagnostic (2026-09-28)

The WIP diagnostics were committed before the measured runs. The 0.2.0 adapter
is active on the Gemma 3 VLM: both stages reported `fused=true` and
`cumulative=true`, both key remaps were identity, and all 12 same-session
comparisons changed the full-vocabulary next-token logits (mean absolute delta
2.503–3.472). Greedy answers changed in all 12 comparisons but contained 0/26
required training symbols. The six verbatim training prompts produced the same
answers under the eval and training system-prompt labels because those two
prompts are byte-equal. The unfused two-stage chain path is unsupported by the
current public activation API. See
`eval_results/round3b-adapter-probe.jsonl` and
`eval_results/round3b-adapter-probe.md`.

This is case 3: inference activation/fusion works, while 0.2.0 does not
reproduce its training examples. A diagnostic SFT-only run then trained 100
steps from the pinned base on the 296-row corpus, rank 8, 16 layers, learning
rate 0.0001, batch size 1, and `steps_per_report=1`. The curve contains all 100
library-indexed steps (0–99): loss fell from 9.1279 to 1.1642; final validation
loss was 0.9919. Loss on all 84 Grant training rows fell from 4.8631 to 0.7719.
This shows the SFT path can fit the Grant training rows in isolation; it does
not establish that a packaged two-stage filter improves held-out results. The
diagnostic adapter stayed in the ignored `.crystal-cache` directory and was
not packaged or installed.

The run used full-sequence SFT (`completion_only_loss=false`), matching the
0.2.0 training mode; the prompt tokens were not masked. In this run,
`template_from` resolved the pinned Gemma 3 chat template and selected the
`GEMMA3` renderer. The first saved `train.jsonl` row matched the training-token
preview exactly; its 287 token IDs decoded to that row with the tokenizer-added
`<bos>` prefix. This observed result differs from the earlier report that
`template_from` returned nil, but there was no rendered-row or decoded-text
mismatch in this run.

The 2048-token warning comes from the pinned upstream
`mlx-swift-lm` revision `e6a753aa9b42cb1a2fb9736e99ed5a4a9f40fb2e`,
`Libraries/MLXLLM/LoraTrain.swift:50-66`. It warns when a batch's
longest tokenized row exceeds 2048, then pads to that batch maximum and shifts
the full sequence into inputs and targets; it does not truncate. The prior
full-corpus audit found 1/296 SFT rows above 2048, maximum 2148. Hypothetical
right truncation would remove 100 tail tokens from that row; actual training
truncation was 0 rows.

Artifacts: `eval_results/round3b-fit100-loss.jsonl`,
`eval_results/round3b-fit100-token-preview.jsonl`, and
`eval_results/round3b-fit100-diagnostic.md`. The next training measurement is
completion-only loss masking, as a single change from the 0.2.0 recipe.
