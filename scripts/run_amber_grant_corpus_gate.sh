#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
export CRYSTAL_CACHE_DIR="$ROOT/.crystal-cache"

python3 scripts/verify_amber_grant_toolchain.py --tools-only
shards-alpha install --frozen
scripts/prepare_pinned_sources.sh
python3 scripts/verify_amber_grant_toolchain.py
python3 scripts/rebuild_amber_v2_sft.py --base-only --output .crystal-cache/amber-v2-base-212.jsonl
python3 scripts/build_amber_grant_pairs.py
python3 scripts/rebuild_amber_v2_sft.py

GATE_LOG="$ROOT/.crystal-cache/amber-grant-gate-final.log"
if ! crystal-alpha run scripts/gate_amber_grant_corpus.cr -- \
  --baseline .crystal-cache/amber-v2-base-212.jsonl > "$GATE_LOG" 2>&1; then
  cat "$GATE_LOG"
  exit 1
fi
tail -n 15 "$GATE_LOG"

crystal-alpha run scripts/gate_amber_grant_corpus.cr -- \
  --baseline .crystal-cache/amber-v2-base-212.jsonl --self-check
