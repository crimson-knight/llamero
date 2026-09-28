#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

RUN_DIR="$ROOT/.crystal-cache/round3b-adapter-probe"
LOG_PATH="$RUN_DIR/probe.log"
ARTIFACT_PATH="$ROOT/training_data/amber/eval_results/round3b-adapter-probe.jsonl"
REPORT_PATH="$ROOT/training_data/amber/eval_results/round3b-adapter-probe.md"
export CRYSTAL_CACHE_DIR="$RUN_DIR/crystal-cache"

if pgrep -f '[c]rystal-alpha run (examples/train_amber_v2_adapter.cr|scripts/eval_amber_grant_filter.cr|scripts/probe_amber_grant_adapter.cr)' >/dev/null; then
  printf 'Another Amber MLX training or evaluation process is active.\n' >&2
  exit 1
fi
if [[ -e "$ARTIFACT_PATH" || -e "$REPORT_PATH" || -e "$LOG_PATH" ]]; then
  printf 'Refusing to overwrite the probe artifact, report, or log.\n' >&2
  exit 1
fi

python3 scripts/verify_amber_grant_toolchain.py --tools-only
shards-alpha install --frozen
scripts/prepare_pinned_sources.sh
python3 scripts/verify_amber_grant_toolchain.py
python3 scripts/verify_amber_model_pin.py

mkdir -p "$RUN_DIR"
nohup crystal-alpha run scripts/probe_amber_grant_adapter.cr \
  >"$LOG_PATH" 2>&1 </dev/null &
JOB_PID=$!
printf '%s\n' "$JOB_PID" >"$LOG_PATH.pid"
printf 'started pid=%s\nlog=%s\nartifact=%s\n' "$JOB_PID" "$LOG_PATH" "$ARTIFACT_PATH"

if wait "$JOB_PID"; then
  printf 'completed pid=%s\n' "$JOB_PID"
else
  JOB_STATUS=$?
  printf 'failed pid=%s status=%s\n' "$JOB_PID" "$JOB_STATUS" >&2
  tail -n 80 "$LOG_PATH" >&2
  exit "$JOB_STATUS"
fi
