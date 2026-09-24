#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_PATH="$ROOT/.crystal-cache/amber-v2-grant-round3-training.log"
PID_PATH="$ROOT/.crystal-cache/amber-v2-grant-round3-training.pid"

if [[ ! -f "$PID_PATH" || ! -f "$LOG_PATH" ]]; then
  printf 'Training PID or log file is missing. Launch with scripts/train_amber_v2_grant_round3.sh first.\n' >&2
  exit 2
fi

while pgrep -F "$PID_PATH" >/dev/null; do
  printf '\n[%s] training process is active\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tail -n 16 "$LOG_PATH"
  sleep 30
done

tail -n 40 "$LOG_PATH"
if grep -Fq 'shipped amber-v2@0.2.0' "$LOG_PATH"; then
  printf '\nTraining completed and the versioned filter was packaged.\n'
else
  printf '\nTraining stopped without a packaged filter.\n' >&2
  exit 1
fi
