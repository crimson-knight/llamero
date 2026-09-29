# Round 3b train/serve loss bisection

- Filter: `amber-v2@0.2.1` (completion-only usage stage, rank 8, scale 1.0, 16 layers).
- Model: `mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2`.
- Rows: the 84 Grant loss-probe rows the trainer itself used (`.crystal-cache/round3b/0.2.1-grant-loss-probe/train.jsonl`, rendered with the pinned Gemma 3 chat template).
- Loss: completion-only, token-weighted, computed by the new bridge entry point `llamero_mlx_session_evaluate_loss` with the same tokenizer wrapper and loss function as `train_adapter`. Script: `scripts/measure_amber_grant_train_serve_loss.cr`.

## Result

| Step on the path from trained adapter to inference | Loss (84 rows) | Rows 1-5 |
| --- | ---: | --- |
| Pinned base, no adapter | 2.9885 | 3.664, 3.155, 3.165, 3.440, 2.731 |
| Stage 0 fused (the base stage 1 trained on) | 1.8960 | 1.686, 1.621, 1.585, 2.217, 1.507 |
| Stage 0 fused + stage 1 **live** LoRA (training state) | **0.2091** | 0.110, 0.091, 0.142, 0.454, 0.141 |
| Stage 0 fused + stage 1 **fused** (re-quantized) | **1.3471** | 1.030, 1.027, 0.948, 1.549, 1.059 |
| `session.activate_filter(filter, fuse: true)` (the eval path before the fix) | 1.3471 | 1.030, 1.027, 0.948, 1.549, 1.059 |
| Stage 1 alone on the base, live | 0.2336 | 0.127, 0.120, 0.220, 0.495, 0.164 |
| Stage 1 alone on the base, fused | 1.6680 | 1.758, 1.627, 1.545, 1.931, 1.532 |

The training run reported usage-stage Grant loss 1.8960 before and 0.2091
after. The bridge reproduces both values exactly (1.8960 on the stage-0-fused
base and 0.2091 with stage 1 live), so the saved safetensors, the key remap
(identity), the layer indices (18-33, the last 16 of 34), the projections
(all seven), and the scale (1.0 in both `adapter_config.json` and training)
are all correct. The loss jumps from 0.2091 to 1.3471 at exactly one step:
`QLoRALinear.fused()`, which dequantizes, adds `scale * B^T A^T`, and
re-quantizes to 4 bits with group size 64.

## Why the fuse erases this adapter

`scripts/estimate_lora_requant_retention.py` replays the fuse in NumPy on the
stored adapter and base weights (see `round3b-requant-retention.txt`; the
replica of MLX affine quantization is close but not bit-exact, so treat it as
supporting evidence, not the measurement). For the 0.2.1 usage stage the
per-element delta has RMS about 2e-4 to 5e-4 and maximum about 2e-3 to 8e-3,
while the median 4-bit step of the same groups is about 1.5e-3 to 8e-3. Most
of the delta is below half a quantization step, so rounding removes it; the
surviving change has cosine 0.06-0.30 with the intended delta. The installed
0.1.0 adapter was trained with `scale: 10` (its manifest says 1.0, but its
`adapter_config.json` says 10); its delta is about six times larger, and the
same replay keeps cosine 0.63-0.95. That is why 0.1.0 survived fusion and
0.2.x did not.

Candidate causes ruled out by the table: layer or projection mismatch (the
live adapter loaded through the same remap path reproduces training loss),
scale mismatch (same), wrong checkpoint saved (same), and chain ordering
(stage 1 alone live gives 0.2336, close to 0.2091; fusing it alone is just as
bad as fusing it on the chain).

## Fix

`ModelSession#activate_filter` now rebuilds a chain exactly as it was trained:
every stage before the last is fused forward (each later stage trained on
that re-quantized base), and the final stage is installed as live LoRA
layers. `cumulative: true` still fuses every stage, for use as a base for
further training.

Raw per-row losses: `round3b-train-serve-loss-0.2.1.jsonl`; run log:
`round3b-train-serve-loss-0.2.1.log`.
