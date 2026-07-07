# GBNF benchmark lab (grammar-constrained generation)

The measured results behind every performance/correctness claim in the main
README's "Grammar-constrained structured output" section live here:

- **`BENCH_RESULTS.md`** — the write-up: environment, protocol, documented
  deviations, tables, findings, threats to validity. Read the Vocabulary
  section first ("oracle pass" is a calibrated partial oracle, not full
  correctness).
- `results/runs.jsonl` — all 300 runs, including the FULL raw text of every
  attempt (`attempt_log[].content`) for independent re-scoring.
- `results/bench_run.log` — the uninterrupted live transcript of the run.
- `src/bench.cr` — the 4-arm harness (build with `shards install && crystal
  build src/bench.cr --release`); `src/schemas.cr` — the task types.
- `analyze.py` / `analyze_fields.py` — table aggregation and per-field
  re-scoring of raw outputs.
- `run_cliff_compile_refusal.sh` + `results/cliff_compile_refusal.txt` — the
  past-budget compile-time refusal, captured.
- `results/archive_pre_audit/` — the earlier partial dataset (pre UTF-8 fix),
  archived and unused, kept for provenance.

Models are NOT checked in (~540 MB): base is SmolLM-135M-Instruct f16
dequantized from `mlx-community/SmolLM-135M-Instruct-4bit`; tuned is the same
checkpoint + a rank-8 LoRA fused by the identical pipeline. Set
`BENCH_BASE_GGUF` / `BENCH_TUNED_GGUF` to your paths to rerun; the harness
refuses to time anything unless the pinned llama.cpp probe passes.

These claims survived three rounds of hostile external methods review
(GPT-5.5 codex, xhigh then medium effort) on 2026-07-07; the final round
returned AUDIT: CLEARED.
