# Gemma 3 4B (and other multimodal Gemma 3) fails to load — config fix

## Symptom

Loading `mlx-community/gemma-3-4b-it-4bit` (or any Gemma 3 4B/12B/27B conversion
that ships a multimodal `config.json`) aborts at model construction:

```
Model load failed: mismatchedSize(
  path: ["model","layers","0","self_attn","k_proj","weight"],
  modules: [Gemma3TextModel, Gemma3Model, Gemma3TransformerBlock,
            Gemma3Attention, QuantizedLinear],
  expectedShape: [256, 320], actualShape: [1024, 320])
```

This happens **at base-model load, before any adapter exists** — it is not an
adapter or LoRA problem.

## Root cause

These multimodal checkpoints nest the text hyperparameters under `text_config`,
and the 4-bit converter (`mlx_lm.convert`) **drops any field equal to the
transformers class default**. For gemma-3-4b that means `text_config` keeps
`hidden_size`/`intermediate_size`/`num_hidden_layers` but **omits**:

- `num_attention_heads`  (true value 8)
- `num_key_value_heads`  (true value 4)
- `head_dim`             (true value 256)

mlx-swift-lm's `Gemma3TextConfiguration` decoder
(`Libraries/MLXLLM/Models/Gemma3Text.swift`) fills missing keys with **1B**
defaults (`attentionHeads ?? 4`, `kvHeads ?? 1`, `headDim ?? 256`). So it builds
`k_proj` as `kvHeads(1) * headDim(256) = 256` while the checkpoint has
`4 * 256 = 1024` → shape mismatch → load aborts.

The checkpoint itself is correct; only the metadata is incomplete. Confirmed
against the weight shapes: `q_proj [2048,320]`=8×256, `k_proj/v_proj [1024,320]`=
4×256, `o_proj [2560,256]`.

## Fix

Restore the three omitted fields to the cached model's `config.json` under
`text_config` (architecturally-correct values for gemma-3-4b):

```json
"text_config": {
  "num_attention_heads": 8,
  "num_key_value_heads": 4,
  "head_dim": 256,
  ...
}
```

After patching, gemma-3-4b loads, generates, and — being a **dense** model
(unlike the Gemma 4 e-series) — its LoRA/QLoRA adapter **does** affect
inference. The FSDD Stage-1 benchmark passes 4/4 on it
(`examples/train_fsdd_feature_story_adapter.cr -- mlx-community/gemma-3-4b-it-4bit`:
base 0/4 → adapter 4/4 → removed 0/4, `load_count=1`).

## Productizing (TODO)

A manual cache edit is not shippable — a fresh download re-breaks, and end users
hit the same wall. `ModelDownloader` should complete known-incomplete Gemma 3
`text_config`s at download time (only add fields that are genuinely missing,
gated on `model_type == "gemma3"` / `gemma3_text`). The per-size head counts:

| model | hidden | n_heads | n_kv_heads | head_dim | layers |
|-------|--------|---------|------------|----------|--------|
| 1B    | 1152   | 4       | 1          | 256      | 26     |
| 4B    | 2560   | 8       | 4          | 256      | 34     |
| 12B   | 3840   | 16      | 8          | 256      | 48     |
| 27B   | 5376   | 32      | 16         | 256      | 62     |

(12B/27B values are the published Gemma 3 architecture; verify against the
checkpoint weight shapes before relying on them, as done for 4B above.)
