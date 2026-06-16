# FSDD stage-expert adapters — vision & roadmap

Captured 2026-06-14 from the owner. This is the strategic "why" behind a large
chunk of llamero's local-inference + adapter-training work. Keep it here in
llamero (the engine) so the training/runtime work stays anchored to the library.

## The bet (one paragraph)

We are building a code editor for **Feature-Story-Driven Development (FSDD)** that
runs **small, fast, on-device language models** specialized per FSDD stage. A
person talks naturally about what they want; the on-device model **structures**
that into valid FSDD artifacts (structured JSON the app consumes), knows **what to
do next**, and knows **when the input isn't actually the work**. Each FSDD stage
gets its own **LoRA adapter** mounted on one tiny **Gemma** base, hot-swapped as
the editor moves through the stages (and the U-shaped flow), so the same small
model becomes an *expert* at whichever stage it's working. It all runs through
**llamero on Apple Silicon** to maximize the hardware we ship on. We already
proved LoRA training works (the dogfood docs adapter); this is the step where we
prove we can **harness behavior tightly and in a performance-structured way**,
not just that it works.

## The pieces that already exist (grounding, not greenfield)

- **The editor** — `~/personal_coding_projects/feature-stories-vscode` (an Electron
  app, historically mislabeled a "VS Code plugin"; the rough draft of the editor,
  already does file viewing/editing and has a feature-story creation surface).
  - Stage docs: `feature-driven-development-docs/layer_1_and_2/refining_a_feature_story.md`,
    `feature_story_development_down.md`, `layer_3/defining_a_technical_feature_story.md`.
  - Grammar: `syntaxes/feature-story.tmLanguage.json`; sample `.story` files under
    `.feature-stories/stories/`.
- **The FSDD "book" / process** — `~/Documents/remote_sync_vault/`:
  `Feature-Story-Driven-Development/`, `Feature Stories Grammar.md`,
  `Feature Stories Notes.md`, `Agent Enhanced Development/`,
  `specialized_agents/{team-fsdd-analyst,team-fsdd-implementer,FSDD_AGENT_ARCHITECTURE.md}`,
  `Projects/FSDD-Plugin-Architecture-Plan.md`. These define what a *valid* feature
  story is and the stages — the spec for the training targets.
- **llamero** — the on-device engine, already has what this needs:
  - **In-process QLoRA training**: `ModelSession#train_adapter(name, dataset, config)`
    on a resident quantized Gemma/Qwen base. Proven (a 0.6B model learned a fact
    set in ~56s; `training_data/` holds the dogfood docs dataset precedent).
  - **Structured output**: `chat_structured` + a `Llamero::BaseGrammar` subclass →
    typed JSON parsed into Crystal classes. This is how we force the small model to
    emit the app's exact response shapes.
  - **Adapter hot-swap**: `activate_adapters` / `deactivate_adapters` with NO base
    reload (`load_count` stays 1) — the mechanism for swapping the per-stage expert.
  - **ModelPool**: multiple small models resident at once (e.g. a dense specialist
    + a chat/thinking layer) — option if a stage needs more than one model.
  - Apple Silicon via MLX/Metal today. (Constraint: **Gemma, ungated; no Chinese
    models** — see `[[user-model-constraints-and-vision]]`.)

## Architecture

```
 natural-language input (user speaks/types)
        │
        ▼
 small Gemma base (resident in llamero, quantized)
   + per-stage LoRA adapter  ◄── activate/deactivate as the editor changes stage
        │
        ▼
 structured JSON (validated by a BaseGrammar schema = the app's expected shape)
   + a "next action" / "is-this-the-work?" decision
        │
        ▼
 the FSDD editor consumes the JSON (creates/updates the feature story, routes next)
```

- **One base, many experts.** Keep the base tiny (Gemma ~1B class, or an e-series
  like gemma-3-e2b) for speed; encode each stage's expertise in a small LoRA. The
  editor mounts the adapter for the current stage. Small + specialized = fast and
  reliable, which beats a big general model for a narrow structured task.
- **Structured-JSON-native.** Every adapter is trained so its output IS the app's
  schema — no post-hoc parsing gymnastics. `BaseGrammar` enforces it at decode.
- **Behavior gating is part of the task.** The model must recognize when input is
  *not* the work it's responsible for (e.g. chit-chat, or work that belongs to a
  different stage) and say so, rather than hallucinate a structure.

## Stage 1 — Feature Story Refinement (where we start)

The first expert. Its job, from the FSDD refinement spec:

1. **Identify** the feature story the person is describing.
2. **Extract** the proper nouns and grammar from natural language (the FSDD grammar
   has specific roles — actors, capabilities, outcomes, etc.; see `Feature Stories
   Grammar.md` + `feature-story.tmLanguage.json`).
3. **Structure** the natural-language ask into a *valid* feature story (per the
   FSDD definition of validity) and emit it as structured JSON matching the app's
   schema.
4. **Reason about next actions** — what the editor should do after this input.
5. **Gate meaningfulness** — detect when the input isn't actually a refinement task
   (and route/decline instead of forcing a structure).

### Training data shape (what we generate, with Claude's help)

Pairs of `{ natural_language_input → { structured_feature_story_json,
extracted_entities, validity, next_action, is_in_scope } }`, deliberately
covering: clean valid asks, ambiguous asks, under-specified asks, invalid /
out-of-scope inputs (the "not the work" cases), and grammar-edge cases (proper
nouns, multi-actor, nested capabilities). The output schema is fixed (a
`BaseGrammar`) so every example trains the model toward the same JSON shape.

## Scaling: an expert per stage + the U-shaped flow

FSDD has defined stages (refinement → technical feature story → implementation
"down" and "up" → tests, per the `feature-driven-development-docs/layer_*` and the
U-shaped process). The plan: **one adapter per stage**, the editor swaps the
active adapter as it walks the U. Same base, swapped expertise, no reload. Build
the pipeline once on Stage 1, then repeat it per stage.

## Apple-hardware angle (and the ANE stretch)

The point of llamero is to extract maximum performance from the Apple Silicon our
apps run on. Today llamero runs the MLX LLMs on the **Metal GPU**; the audio
CoreML models (Parakeet/Kokoro) run on the **ANE**. The stretch goal: get **LLM
inference onto the ANE** (CoreML-converted small models) for even faster,
lower-power on-device inference — likely worth a dedicated research workflow
(feasibility of CoreML/ANE for a quantized Gemma-class model + LoRA, vs MLX/Metal).

## Next concrete steps

1. **Extract the Stage-1 spec**: read `Feature Stories Grammar.md`,
   `refining_a_feature_story.md`, and the `.story`/tmLanguage grammar → define the
   exact "valid feature story" structure and the entities to extract.
2. **Define the Stage-1 output schema** as a `Llamero::BaseGrammar` subclass (the
   JSON the editor consumes) — including the `is_in_scope` / `next_action` fields.
3. **Generate Stage-1 training data** — a llamero-driven workflow that iterates
   producing diverse `{input → structured output}` pairs (Claude/a larger model
   generates; we validate against the schema). Aim for tight, performance-
   structured behavior, not just coverage.
4. **Train + verify the Stage-1 LoRA** on a small Gemma via `train_adapter`;
   verify: schema-valid JSON every time, correct entity extraction, correct
   in-scope gating, and on-device latency on Apple Silicon.
5. **Wire into the editor** (`feature-stories-vscode`) via llamero, adapter mounted
   for the refinement stage.
6. **ANE-for-LLM research** — separate workflow.

## Open questions for the owner

- Base model choice for the experts (gemma-3-1b vs an e-series e2b — speed vs
  capability for structured extraction)?
- Confirm the canonical list/order of FSDD stages to target (from the U-shaped
  process) so we can plan the adapter set.
- Where the editor should call llamero from (the Electron app shells out / FFI /
  a local llamero service)?
