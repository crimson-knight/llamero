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
