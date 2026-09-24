#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CRYSTAL_CACHE_DIR="$ROOT/.crystal-cache"

if [[ $# -ne 3 ]]; then
  printf 'Usage: %s <before|after> <filter-path> <output.jsonl>\n' "$0" >&2
  exit 2
fi

python3 scripts/verify_amber_grant_toolchain.py --tools-only
shards-alpha install --frozen
scripts/prepare_pinned_sources.sh
python3 scripts/verify_amber_grant_toolchain.py
python3 scripts/verify_amber_model_pin.py
crystal-alpha run scripts/eval_amber_grant_filter.cr -- "$1" "$2" "$3"
