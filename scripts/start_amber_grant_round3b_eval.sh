#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CRYSTAL_CACHE_DIR="$ROOT/.crystal-cache/round3b-eval"
export AMBER_GRANT_EVAL_PATH="$ROOT/training_data/amber/grant_tenancy_eval_r3b.jsonl"

if [[ $# -ne 4 ]]; then
  printf 'Usage: %s <run-id> <filter-path> <artifact.jsonl> <log-path>\n' "$0" >&2
  exit 2
fi

RUN_ID="$1"
FILTER_PATH="$2"
ARTIFACT_PATH="$3"
LOG_PATH="$4"
if [[ ! "$RUN_ID" =~ ^round3b-[a-z0-9.-]+-run-[12]$ ]]; then
  printf 'Invalid run ID: %s\n' "$RUN_ID" >&2
  exit 2
fi
if [[ -e "$ARTIFACT_PATH" || -e "$LOG_PATH" ]]; then
  printf 'Refusing to overwrite an eval artifact or log.\n' >&2
  exit 2
fi
if [[ ! -f "$FILTER_PATH/training_filter.json" ]]; then
  printf 'Filter package is missing: %s\n' "$FILTER_PATH" >&2
  exit 2
fi

python3 scripts/verify_amber_grant_toolchain.py --tools-only
shards-alpha install --frozen
scripts/prepare_pinned_sources.sh
python3 scripts/verify_amber_grant_toolchain.py
python3 scripts/verify_amber_model_pin.py

mkdir -p "$(dirname "$ARTIFACT_PATH")" "$(dirname "$LOG_PATH")"
nohup crystal-alpha run scripts/eval_amber_grant_filter.cr -- \
  "$RUN_ID" "$FILTER_PATH" "$ARTIFACT_PATH" >"$LOG_PATH" 2>&1 </dev/null &
JOB_PID=$!
printf '%s\n' "$JOB_PID" >"$LOG_PATH.pid"
printf 'started pid=%s\nlog=%s\nartifact=%s\n' "$JOB_PID" "$LOG_PATH" "$ARTIFACT_PATH"
if wait "$JOB_PID"; then
  printf 'completed pid=%s\n' "$JOB_PID"
else
  JOB_STATUS=$?
  printf 'failed pid=%s status=%s\n' "$JOB_PID" "$JOB_STATUS" >&2
  tail -n 40 "$LOG_PATH" >&2
  exit "$JOB_STATUS"
fi
