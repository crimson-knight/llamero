#!/bin/bash
# Fresh-download smoke: proves a NEW user's first run works, using an isolated
# LLAMERO_HOME so the warm ~/.llamero cache can't mask upstream breakage (the
# 2026-07-06 gemma-4-e2b re-upload sailed past every warm-cache test).
#
# Downloads ~3.4GB on each run - this is a release gate, not a per-commit hook.
set -euo pipefail
cd "$(dirname "$0")/../.."

if [ ! -f native/llamero-mlx/.build/release/libLlameroMLXBridge.dylib ]; then
  echo "Bridge not built - run native/llamero-mlx/build.sh first" >&2
  exit 1
fi

SCRATCH="$(mktemp -d /tmp/llamero-fresh-smoke.XXXXXX)"
trap 'rm -rf "$SCRATCH"' EXIT
echo "== fresh-download smoke (isolated LLAMERO_HOME=$SCRATCH) =="

LLAMERO_HOME="$SCRATCH" crystal run examples/native_smoke_test.cr 2>&1 | tee "$SCRATCH/out.log"

grep -q "SMOKE TEST PASSED" "$SCRATCH/out.log" || { echo "FRESH-DOWNLOAD SMOKE FAILED"; exit 1; }
echo "FRESH-DOWNLOAD SMOKE PASSED"
