# Adapter composition — experiments & decisions (Phase C)

How do we compose multiple trained capabilities (Crystal → Amber → product) into
one model? Two candidate mechanisms, and what we've measured / will measure.

## Decision (current): fuse-forward is the production path

Recorded in `distributable_crystal_model_vision.md`. A LoRA is an additive
low-rank delta `W' = W + scale·(B·A)`. Two ways to stack N of them:

- **Runtime n-way stacking** — keep N adapters live and sum their deltas at
  inference: `W + Σ ΔWᵢ`. Each `ΔWᵢ` was trained assuming an *unmodified* base,
  so at runtime each adapter sees the others' deltas as unseen noise; they can
  interfere, and it compounds with N. The bridge rejects this today
  (`Bridge.swift:731`) rather than silently approximating.
- **Fuse-forward** — train adapter 1, fuse it into the (re-quantized) base, train
  adapter 2 *on that fused base*, fuse, … Each stage is trained against the exact
  weights it will run on, so there's no train/run mismatch and no interference.
  This is what `StagedPipeline` + cumulative fuse implement, and it's proven
  (the spine ran unsupervised→SFT→GRPO end-to-end; the 2-stage fuse-forward test
  passed 4/4: base 0.0 → +A 0.833 → +A+B 1.0, B trained on the A-fused base).

The remaining honest unknowns are the two experiments below.

## Experiment 1 — N-stage fuse-forward re-quant drift (RUNNABLE NOW)

**Question.** Each cumulative fuse dequantizes → adds `scale·(B·A)` → *re-quantizes*
the 4-bit base. Does that quantization error **compound** across many stages and
eventually degrade the model?

**Design** (`examples/fuse_forward_drift.cr`). Train 5 stages that all teach the
*same* good behavior (clean Crystal `record` output) on different content slices,
and measure a **fixed** held-out (compile+format rubric) after each fuse. Because
the taught behavior is constant, any decline after stage k is re-quant drift, not
forgetting. The example runs two passes: (1) NAIVE unconditional fuse, and (2)
GUARDED via `StagedPipeline` with `guard: true`.

**Result — drift is real and unbounded under naive fusing.** On
`gemma-3-1b-it-4bit`, two naive runs:

```
run 1: [0.0,   0.75, 0.875, 1.0, 0.125, 0.5 ]   peak 1.0 -> final 0.5   (collapse at fuse 4)
run 2: [0.125, 0.75, 0.5,   1.0, 0.75,  0.75]   peak 1.0 -> final 0.75  (drift down from peak)
```

Fuse-forward climbs cleanly for ~3 stages, reaches a peak, then re-quant error
(compounded with sampling variance) pulls it back down — sometimes a hard
collapse. So **naive fuse-forward is reliable to ~3 stages on a small 4-bit base,
not arbitrarily deep.** The vision's 3-layer plan (Crystal → Amber → product) sits
right at that stable boundary; deeper stacks need the guard below, a
higher-precision base, or fewer fused layers.

**Result — the guard bounds the drift.** The key subtlety: re-quantization happens
*during* the fuse, so a pre-fuse *live* preview of an adapter cannot see
fuse-induced drift. The guard therefore measures the **real composed model after
each fuse** and, on regression, rolls back by **reloading the base and replaying
every kept stage's fuse** (`StagedPipeline#replay`). In the guarded run:

```
kept s0,s1,s2 (0.75, 0.875, 0.875) -> s3 fused to 0.5 < 0.875 -> ROLLED BACK
 -> s4 trained on the replayed 3-stage base, fused to 0.875 -> KEPT
guarded final 0.875  vs  naive final 0.75
```

The composition is monotonic: a stage that drifts (or collapses) is dropped, and
training continues on the reconstructed good base. This is the same guard that
drops a collapsing GRPO stage in the spine — measuring after the fuse makes it
catch re-quant drift too.

**Forgetting variant** (future): train stage 1 on behavior A, stages 2..k on an
*unrelated* behavior B, then re-measure A — bounds catastrophic forgetting across
fuses (distinct from re-quant drift).

## Experiment 2 — runtime n-way stacking vs fuse-forward (DEFERRED RESEARCH)

**Question.** Is summed-delta runtime stacking ever competitive with fuse-forward,
and how fast does interference grow with N? If it's stable for small N it would
let a consumer load several library filters without re-fusing.

**Why deferred.** It requires lifting the bridge's single-adapter limit, which is
a non-trivial, on-device-only Swift change:

1. In `llamero_mlx_session_activate_adapters` (`Bridge.swift`), replace the
   `payload.slots.count > 1` rejection with a loop that loads **every** slot's
   `LoRAContainer` into the model (instead of only `payload.slots.first`), and
   record all of them in `session.activeAdapters` for clean unload.
2. Honor per-slot `scale` (currently also rejected) so the experiment can sweep
   blend weights — verify `LoRAContainer.load` applies a per-container scale, or
   thread it through `QLoRALinear`.
3. Confirm mlx-swift-lm's LoRA application composes when multiple containers wrap
   the same `Linear` (nest → sum of deltas) rather than the last one replacing
   the others; this is the crux and must be checked against the library, not
   assumed.
4. Matching Crystal side: `AdapterStack.additive` already carries multiple slots;
   relax `ModelSession`/`mlx_bridge.cr` so multi-slot stacks reach the bridge.

**Comparison protocol.** Train two adapters A, B on the *same* base (NOT
fuse-forward). Then compare on a held-out that needs both capabilities:
- (a) runtime stack A+B (summed deltas, the lifted path),
- (b) fuse-forward A→B,
- (c) A-only and B-only as floors.
Sweep N = 2..4 to chart interference growth, and sweep per-slot scale for (a).

**Decision criterion.** Adopt runtime stacking only if it's within a small
tolerance of fuse-forward for the N we care about (≤ 2–3 library filters) *and*
avoids a re-fuse step a consumer can't run. Otherwise it stays a research option
and **fuse-forward + modular-at-distribution** (one filter per artifact, each
trained on the exact base it runs on) remains the shipped design — which already
gives full modularity without runtime stacking.

## Bottom line

The production decision does **not** depend on Experiment 2: distribution is
modular at the artifact layer (Phase E), composition is fuse-forward. Experiment 1
validates that fuse-forward *scales* past two stages; Experiment 2 is upside that
would simplify the consumer story if it proves stable, and is scoped above so it
can be picked up without re-deriving the plan.
