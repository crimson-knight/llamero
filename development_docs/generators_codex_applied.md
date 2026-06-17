# Error-repair & spec generators — Codex review, applied

Codex (read-only) reviewed both generators; full critique in
`codex_crystal_corpus_critique.md` (corpus) and its generator review. This records
what's APPLIED vs QUEUED so the partnership feedback isn't lost.

## Error-repair generator (`src/native/error_repair.cr`)

Codex's core point: the skew (83% missing-`end`) is a symptom of Crystal's **lazy
checking** — semantic errors (type/arity/nil) only surface when code is
*instantiated*; definition-only snippets yield mostly syntax errors.

**Applied now:**
- Added `corrupt-type` mutation: corrupt a type annotation (`: Foo` → `: FooZz`)
  → "undefined constant", checked at DEFINITION time, so it surfaces broadly
  without instantiation. Gives a large undefined-const family.
- Family balancing in the generator: cap any single mutation family to ≤20% of
  the dataset; dedup by (mutation, error, fix). So `drop-end` no longer dominates.
- Mutations skip comment lines.

**Queued (need a usage harness — Codex's main structural ask):**
- A generated **usage harness** that instantiates each program so TYPE-MISMATCH,
  ARITY, NIL-SAFETY, BLOCK-ARG, and OVERRIDE errors actually surface. This is the
  unlock for the type/nil/arity families (currently underrepresented).
- Ruby→Crystal mistakes as a family (`.length`→`.size`, `.include?`→`.includes?`)
  — only meaningful with instantiation.
- **Minimal-diff completions** as the primary target (Codex: full-program wastes a
  1B's loss on copying unchanged code; a patch teaches "localize the fix"). Keep
  full-program as an auxiliary/eval target. Needs an apply-and-compile gate.
- Target family mix: syntax 10-15%, undefined 25%, type/return 25%, nil 15%,
  arity/block 15%, override/misc 5-10%; cap exact error text ≤10%.
- Split train/test by *original program*, not by pair.

## Spec generator (`src/native/spec_runner.cr`)

Codex's core point: `impl → passing spec` only gates SYNTAX/PASS, not MEANING — a
tautology passes.

**Applied now (the standout idea):**
- **Mutation-testing meaningfulness gate.** `SpecRunner.meaningful?(impl, spec)` =
  the spec passes the correct impl AND **kills ≥1 behavior mutant** — mutants that
  still COMPILE but change behavior (`+`↔`-`, `<`↔`>`, `==`↔`!=`, drop `.sort`/
  `.uniq`, `true`↔`false`, …). A `(1+1).should eq 2` spec kills nothing → rejected;
  a spec that asserts real outputs + edge cases kills mutants → accepted. Verified.
- Worker prompt forbids tautologies / empty examples / focused specs / reopening
  the subject / `Process.run`/`system`/`sleep`/network/exit, and requires multiple
  `it` blocks + edge cases.

**Queued:**
- Stronger mutation set + a minimum mutation-KILL-RATE threshold (kill ≥M of K),
  not just ≥1.
- Public-method coverage check (every public method exercised).
- Other shapes Codex named: `directive+spec → impl` (TDD), and
  `impl + failing-spec output → patch` (repair/RL).
- `wrap` should detect real `require` lines, not substring matches in comments.

## Both feed RL
Error-repair → reward = the fix compiles. Spec → reward = generated spec is
meaningful (passes + kills mutants), and `impl+failing-spec → patch` → reward =
spec now passes. These deterministic, gradable rewards are why Codex (and we) rank
these two categories highest for moving the 1B toward dependable behavior.
