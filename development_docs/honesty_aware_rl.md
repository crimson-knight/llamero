# Honesty-aware RL for FSDD / Agent-Enhanced-Development code

The goal of this training is **deliberately biased**: we want a model the owner can
*rely on for accuracy*. That means training it to follow Feature-Story-Driven
Development (FSDD) + Agent-Enhanced-Development (AED) conventions, and — above all
— to **stop lying**. When it does not know an implementation it must scaffold
honestly (typed signature + return type + a `# TODO`/comment stub) instead of
fabricating a plausible-looking body. This mirrors FSDD's own rule:

> "Pretending you have full coverage when you don't is **worse than admitting the
> gap**." — FSDD, U-shaped-flow

So the reward must make a confident hallucination score **worse** than an honest
admission. This is the inversion the owner asked for, and it is exactly what GRPO
needs: when the model samples K completions for a prompt it cannot fully answer,
the honest-stub samples must out-score the fabricated ones so the gradient pushes
toward honesty.

## The grading ladder (harshest → best)

Encoded in `Llamero::Native::FSDDReward` (`src/native/fsdd_reward.cr`). The exact
numbers are tunable constants; the **ordering is the invariant**.

| Tier | Condition | Score | Rationale |
|---|---|---|---|
| 0 | **Foreign-language / made-up constructs** (PHP `$x`, `public function`, `console.log`, `attr_accessor`, Rails-isms…) | **0.0** | The harshest: confidently answering in the wrong language / inventing syntax. |
| 1 | **Invalid Crystal syntax** (does not parse) | **0.1** | Broken / hallucinated syntax. |
| 2 | **Parses, but uses ungrounded framework symbols** (APIs absent from the real Amber/Crystal source) | **0.15–0.30** (scales with grounded fraction) | Confident fabrication of real-looking APIs — "lying." |
| 3 | **Valid + grounded, but wrong/incomplete** | **~0.5** | Honest mistake — "precise but slightly wrong" gets a *less harsh* grade. |
| 4 | **Honest scaffold** (typed signature + return type + comment/TODO stub, or an explicit admitted gap) | **≥ 0.70** (the *honesty floor*) | Admitting > guessing. Above any fabrication. |
| 5 | **Correct + conventions + compiles** | **→ 1.0** | Naming/types/docs bonuses + the compile bonus. |

Key property: **honesty floor (0.70) > fabrication (≤0.30)** and ≥ a
plausible-but-wrong compiling answer. A well-typed, well-named honest stub lands
~0.70–0.85; a correct *compiling* implementation adds the compile bonus to reach
~0.9–1.0. The model is therefore trained: if you don't know, scaffold and say so.

## Signals (all on-device, deterministic where possible)

- **foreign?** — curated high-confidence markers of other languages / invented
  syntax. Tier-0 trigger.
- **parses?** — `crystal tool format -` exits 0 (parses; formatting-agnostic — we
  do NOT use `--check`, which also fails on merely-unformatted valid code).
- **grounded** — each framework symbol the code uses must appear in the real
  Amber/Crystal source (the same word-boundary grep gate used to curate the
  corpus). Pluggable: the reward takes a `grounding` proc so the deterministic
  core is testable without the Amber repo present.
- **honest_stub? / admits_gap?** — a typed-signature method whose body is only
  comments, or a defer marker (`# TODO`, `# MARK: NOT COVERED`, `# requires
  operator input`, `# ...goes here`, `# deferred`). The FSDD scaffold pattern.
- **typed_method_fraction** — fraction of `def`s with an explicit return type
  (AED rule 1: "every method has an explicit return type. Explicit > clever").
- **naming_score** — mechanical convention checks: `*Controller` class naming,
  RESTful action names (no `list`/`get_all`/`remove`…), `list_of_`/`collection_of_`
  prefixes on `Array` properties, `is_`/`has_`/`should_` on `Bool` properties,
  no `puts`, `JSON::Serializable` over hand-rolled `JSON.parse`.
- **compiles** (Tier-5 bonus, pluggable) — snippet written into a scaffolded Amber
  app + `crystal build --no-codegen`. `amber-lsp` is regex-only and cannot do
  this; the compiler is the real judge. Optional because it needs the scaffold.

## What feeds it (the training data)

GRPO only amplifies behavior already present in the model's samples, so we also
need SFT pairs that *demonstrate* the honest scaffold + AED conventions. A
curation round (agent fan-out, grounded in the vault's FSDD/AED docs + Amber
source) produces pairs whose completions are:
1. **Outline-first**: `perform` = a checklist of named `private def`s; typed
   signatures; `# business logic goes here` stub bodies.
2. **Admit-gap**: when the implementation is unknown, a typed signature + return
   type + `# TODO: <what's needed>` / `# requires operator input`, explicitly.
3. **Fully typed + conventionally named** (the AED criteria).
4. **Contrastive** GOOD (scaffold) vs BAD (implementation-dump / fabrication),
   mirroring FSDD's own GOOD/BAD `perform` examples.

## Pipeline

1. **Reward** (`FSDDReward`) — built + unit-tested here (deterministic core).
2. **Amber-compile judge** — a scaffolded throwaway Amber app + a Crystal harness
   that writes a snippet into the right dir and runs `crystal build --no-codegen`;
   wired as the `compiles` proc and the `grounding` source.
3. **FSDD SFT corpus** — curation round → `training_data/amber/fsdd_*.jsonl`.
4. **GRPO** — `session.grpo_train` with `FSDDReward` over held-out feature
   prompts, on the Amber-v2 SFT base, using the drift-robust StagedPipeline guard.

## Source of the conventions
`~/Documents/remote_sync_vault/Agent Enhanced Development/` (coder-amber-v2-criteria,
naming overview, cheat sheet) and `Feature-Story-Driven-Development/` (Part-2
naming/controller conventions, Part-5 process-manager + U-shaped-flow + boundary
testing). The judge tooling lives in `amber_cli` (amber-lsp, regex rules) and the
`amber` repo (the framework, buildable as a dependency).
