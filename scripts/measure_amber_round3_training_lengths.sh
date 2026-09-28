#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

python3 scripts/verify_amber_model_pin.py
LLAMERO_GEMMA3_MODEL_DIR="/Users/crimsonknight/.llamero/models/mlx-community--gemma-3-4b-it-4bit" \
LLAMERO_AMBER_CORPUS_PATH="$ROOT/training_data/amber/amber_v2_sft.jsonl" \
  /usr/bin/swift test --package-path native/llamero-mlx \
  --filter AdapterKeyRemappingTests/testRound3TrainingCorpusLengthDistribution
