#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FILTER_VERSION="0.2.2"
FILTER_PATH="/Users/crimsonknight/.llamero/filters/amber-v2-${FILTER_VERSION}.filter"
INITIAL_FILTER_PATH="/Users/crimsonknight/.llamero/filters/amber-v2.filter"
MODEL_ID="mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2"
MODEL_PATH="/Users/crimsonknight/.llamero/models/mlx-community--gemma-3-4b-it-4bit"
RUN_DIR="$ROOT/.crystal-cache/round3b-${FILTER_VERSION}"
LOG_PATH="$RUN_DIR/training.log"

export CRYSTAL_CACHE_DIR="$RUN_DIR/crystal-cache"

if pgrep -f '[c]rystal-alpha run examples/train_amber_v2_adapter.cr|[a]gent-crystal-bin run examples/train_amber_v2_adapter.cr|[c]rystal-alpha run scripts/eval_amber_grant_filter.cr|[a]gent-crystal-bin run scripts/eval_amber_grant_filter.cr' >/dev/null; then
  printf 'Another Amber training or evaluation process is already running.\n' >&2
  exit 1
fi
if [[ -e "$FILTER_PATH" ]]; then
  printf 'Refusing to overwrite filter: %s\n' "$FILTER_PATH" >&2
  exit 1
fi
if [[ -e "$LOG_PATH" ]]; then
  printf 'Refusing to overwrite training log: %s\n' "$LOG_PATH" >&2
  exit 1
fi
if [[ ! -f "$INITIAL_FILTER_PATH/training_filter.json" ]]; then
  printf 'Initial Amber filter package is missing: %s\n' "$INITIAL_FILTER_PATH" >&2
  exit 1
fi

python3 scripts/verify_amber_grant_toolchain.py --tools-only
shards-alpha install --frozen
scripts/prepare_pinned_sources.sh
python3 scripts/verify_amber_grant_toolchain.py
python3 scripts/verify_amber_model_pin.py

mkdir -p "$RUN_DIR"
nohup crystal-alpha run examples/train_amber_v2_adapter.cr -- \
  "$MODEL_ID" 200 400 "$FILTER_VERSION" "$FILTER_PATH" "$MODEL_PATH" completion-only "$INITIAL_FILTER_PATH" \
  >"$LOG_PATH" 2>&1 </dev/null &
JOB_PID=$!
printf '%s\n' "$JOB_PID" >"$LOG_PATH.pid"
printf 'started pid=%s\nlog=%s\nfilter=%s\ninitial-filter=%s\n' "$JOB_PID" "$LOG_PATH" "$FILTER_PATH" "$INITIAL_FILTER_PATH"

if wait "$JOB_PID"; then
  printf 'completed pid=%s\n' "$JOB_PID"
else
  JOB_STATUS=$?
  printf 'failed pid=%s status=%s\n' "$JOB_PID" "$JOB_STATUS" >&2
  tail -n 60 "$LOG_PATH" >&2
  exit "$JOB_STATUS"
fi
