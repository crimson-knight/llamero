#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CRYSTAL_CACHE_DIR="$ROOT/.crystal-cache"

PINNED_MODEL="mlx-community/gemma-3-4b-it-4bit@93724907d4ed1745d2fe50baadf3b0b01a65abf2"
MODEL_DIR="$HOME/.llamero/models/mlx-community--gemma-3-4b-it-4bit"
FILTER_PATH="$HOME/.llamero/filters/amber-v2-0.2.0.filter"
ADAPTER_ROOT="$HOME/.llamero/adapters"
LOG_PATH="$ROOT/.crystal-cache/amber-v2-grant-round3-training.log"
PID_PATH="$ROOT/.crystal-cache/amber-v2-grant-round3-training.pid"

if [[ -e "$FILTER_PATH" ]]; then
  printf 'Refusing to overwrite existing filter: %s\n' "$FILTER_PATH" >&2
  exit 1
fi
for STAGE in syntax usage; do
  STAGE_PATH="$ADAPTER_ROOT/amber-v2-0.2.0-$STAGE"
  if [[ -e "$STAGE_PATH" ]]; then
    printf 'Refusing to overwrite existing adapter: %s\n' "$STAGE_PATH" >&2
    exit 1
  fi
done

python3 scripts/verify_amber_grant_toolchain.py --tools-only
shards-alpha install --frozen
python3 scripts/verify_amber_grant_toolchain.py
python3 scripts/verify_amber_model_pin.py --model-dir "$MODEL_DIR"
mkdir -p "$ROOT/.crystal-cache"
nohup crystal-alpha run examples/train_amber_v2_adapter.cr -- \
  "$PINNED_MODEL" 200 400 0.2.0 "$FILTER_PATH" "$MODEL_DIR" \
  > "$LOG_PATH" 2>&1 &
TRAIN_PID=$!
printf '%s\n' "$TRAIN_PID" > "$PID_PATH"
printf 'Started training PID %s\nLog: %s\nFilter destination: %s\n' \
  "$TRAIN_PID" "$LOG_PATH" "$FILTER_PATH"
