# Crystal directive corpus — criteria (v2, the reshape)

The bar is **excellent, not decent**: the 1B model should write idiomatic Crystal
and use our tools as well as Haiku does, runnable locally; the 4B should be clearly
better. The shipped artifact is the open-source `crystal` filter.

## Why v1 was wrong
v1 pairs were extracted from stdlib doc comments: the *prompt* was an API
description ("`Top Level Namespace#loop` — Repeatedly executes the block") and the
*completion* was a REPL-style doc snippet — **83% contained `# =>` output
annotations**, many had `# ...` placeholders. That teaches the model to describe
APIs and annotate outputs, not to *do tasks*. It's fine as unsupervised knowledge
(and that stage did help), but it is the wrong shape for SFT. Use it for
unsupervised pretraining only; SFT/RL need directive→implementation pairs.

## v2 shape: DIRECTIVE → complete idiomatic implementation
- **Prompt = a directive (imperative), not a question.** Two flavors:
  1. **Greenfield**: "Write a class `InventoryLedger` that tracks stock per SKU and
     can apply a signed adjustment." → the full class.
  2. **Contextual edit**: given existing code in the prompt, "Update the `show`
     action to return 404 when the record is missing." → ONLY the changed code.
- **Completion = complete, idiomatic, latest-Crystal implementation:**
  - Typed PUBLIC API: method parameters + explicit return types on public
    methods. Locals are typed only when it aids clarity (Crystal infers locals
    and block args — over-typing everything reads unidiomatic). [Codex]
  - **Idiomatic Crystal naming (decided 2026-06-17): the public `crystal` filter
    uses standard Crystal idiom — `?`-predicates (`empty?`, `valid?`, `active?`),
    plural nouns for collections (`users`, `line_items`, `orders_by_id`).** Do NOT
    use the AED `is_/has_/list_of_` conventions here — those belong to the Amber/
    product filter that layers on top. Idiomatic short names are fine where
    conventional (`io`, `id`, `db`, `i`, `x`, `y`, `e`, tight block vars). [Codex]
  - **Latest idiom only — Crystal 1.20.x.** NO APIs deprecated in 1.20 (e.g. use
    `Time.instant`, never the deprecated monotonic clock; the 26-symbol
    deprecation list is in `training_data/crystal/version_facts.jsonl`).
  - NO `# =>` output annotations, NO `# ...`/TODO placeholders (this is the
    *complete-implementation* corpus; honest-stub behavior is a separate corpus).
  - Compiles clean and is already `crystal tool format`-clean.

## Variety / representativeness (must cover the real surface)
Spread across categories, with a difficulty range in each:
data structures & Enumerable; strings & parsing; File/IO; error handling &
nil-safety (`?`/`rescue`/`Result`-style); structs/records & `JSON::Serializable`;
classes, modules, generics; concurrency (Fiber/Channel — latest, incl. the new
execution-context model where relevant); Time/dates (latest API); CLI/OptionParser;
Hash/Set/Tuple/NamedTuple; macros (light). Bias toward tasks a developer actually
asks for, not stdlib trivia.

## Quality gates (deterministic, before human review)
1. **Compile-gate**: `crystal build --no-codegen` against 1.20 (pure Crystal
   verifies standalone).
2. **Format-gate**: `crystal tool format --check` clean.
3. **Deprecation-gate**: reject any completion using a symbol on the 1.20
   deprecation list; prefer the documented replacement.
4. **Shape-gate**: reject completions containing `# =>` or `# ...` placeholders.

## Version history (supplementary, separate)
A distinct fact set (release / patch notes, what-changed-when) so the model *knows*
version differences — but every *implementation* example uses the latest idiom
only. The model's default source of thinking is the latest release.

## Human-in-the-loop review
1. Generate a representative batch under these criteria, deterministically gated.
2. **Codex** gives an independent critique of the criteria + a sample.
3. The owner reviews the batch in the **review tool** (approve / reject / edit +
   notes), exporting decisions.
4. Incorporate feedback → refine criteria → scale generation.
Repeat until the corpus is excellent + representative.
