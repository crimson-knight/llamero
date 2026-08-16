#!/bin/bash
# End-to-end Gemma VLM smoke test for both path and encoded-JPEG C ABI calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
MODEL_ID="${1:-mlx-community/gemma-3-4b-it-qat-4bit@3d9ef289111449933c22761961f16a5df237ce2a}"
SMOKE_TMP="$(mktemp -d -t llamero-vision-smoke)"
FIXTURE="$SMOKE_TMP/red-circle.jpg"
TRANSCRIPT="$SMOKE_TMP/transcript.txt"

cleanup() {
  rm -rf "$SMOKE_TMP"
}
trap cleanup EXIT

cd "$REPO_ROOT"
swift examples/make_vision_fixture.swift "$FIXTURE"
crystal-alpha run examples/native_vision_test.cr -- "$MODEL_ID" "$FIXTURE" both | tee "$TRANSCRIPT"

assert_red_circle() {
  local section="$1"
  local answer
  answer="$(sed -n "/${section}_ANSWER_BEGIN/,/${section}_ANSWER_END/p" "$TRANSCRIPT")"
  if ! grep -Eiq 'red|crimson|scarlet' <<<"$answer"; then
    echo "FAIL: $section answer did not identify the red color" >&2
    exit 1
  fi
  if ! grep -Eiq 'circle|circular|round' <<<"$answer"; then
    echo "FAIL: $section answer did not identify the circle shape" >&2
    exit 1
  fi
}

assert_red_circle PATH
assert_red_circle BYTES
echo "VISION_SMOKE_PASSED (path + JPEG bytes: red circle recognized)"
