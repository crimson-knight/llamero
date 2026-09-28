#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUN_DIR="$ROOT/.crystal-cache/round3b-fit100-launch"
WORK_DIR="$ROOT/.crystal-cache/round3b-fit100"
LOG_PATH="$RUN_DIR/fit100.log"
LOSS_PATH="$ROOT/training_data/amber/eval_results/round3b-fit100-loss.jsonl"
TOKEN_PREVIEW_PATH="$ROOT/training_data/amber/eval_results/round3b-fit100-token-preview.jsonl"
REPORT_PATH="$ROOT/training_data/amber/eval_results/round3b-fit100-diagnostic.md"
export CRYSTAL_CACHE_DIR="$RUN_DIR/crystal-cache"

if pgrep -f '(^|/)(agent-crystal-bin|crystal-alpha) run (examples/train_amber_v2_adapter\.cr|scripts/eval_amber_grant_filter\.cr|scripts/probe_amber_grant_adapter\.cr|scripts/diagnose_amber_grant_fit\.cr)' >/dev/null; then
  printf 'Another Amber MLX training, evaluation, or diagnostic process is active.\n' >&2
  exit 1
fi
if [[ -e "$LOSS_PATH" || -e "$TOKEN_PREVIEW_PATH" || -e "$REPORT_PATH" || -e "$LOG_PATH" || -e "$WORK_DIR" ]]; then
  printf 'Refusing to overwrite the fit diagnostic artifact, work directory, or log.\n' >&2
  exit 1
fi

python3 scripts/verify_amber_grant_toolchain.py --tools-only
shards-alpha install --frozen
scripts/prepare_pinned_sources.sh
python3 scripts/verify_amber_grant_toolchain.py
python3 scripts/verify_amber_model_pin.py

mkdir -p "$RUN_DIR"
nohup crystal-alpha run scripts/diagnose_amber_grant_fit.cr \
  >"$LOG_PATH" 2>&1 </dev/null &
JOB_PID=$!
printf '%s\n' "$JOB_PID" >"$LOG_PATH.pid"
printf 'started pid=%s\nlog=%s\nlosses=%s\ntoken-preview=%s\nreport=%s\n' \
  "$JOB_PID" "$LOG_PATH" "$LOSS_PATH" "$TOKEN_PREVIEW_PATH" "$REPORT_PATH"

if wait "$JOB_PID"; then
  printf 'completed pid=%s\n' "$JOB_PID"
else
  JOB_STATUS=$?
  printf 'failed pid=%s status=%s\n' "$JOB_PID" "$JOB_STATUS" >&2
  tail -n 100 "$LOG_PATH" >&2
  exit "$JOB_STATUS"
fi
