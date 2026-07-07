#!/bin/sh
# Installs the EXACT llama.cpp build that this version of llamero supports.
#
# The pin (tag + commit) lives in src/llamacpp/support.cr - this script parses
# it from there so the code and the installer can never disagree. The build is
# installed OUTSIDE lib/ (shards regenerates lib/) into:
#
#   ${LLAMERO_HOME:-$HOME/.llamero}/llamacpp/<tag>/bin/llama-completion
#
# Usage:
#   sh scripts/install_llamacpp.sh               # install (idempotent)
#   sh scripts/install_llamacpp.sh --force       # rebuild even if present
#   sh scripts/install_llamacpp.sh --postinstall # never fails the shards install:
#                                                # on any error it prints the manual
#                                                # command and exits 0
#
# shard.yml runs this with --postinstall on `shards install`, opportunistically.
# `shards install --skip-postinstall` skips it, which is why llamero also has a
# MANDATORY runtime probe that fails closed with this exact command.

MODE="install"
FORCE=0
for arg in "$@"; do
  case "$arg" in
    --postinstall) MODE="postinstall" ;;
    --force) FORCE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[llamero-llamacpp] $*"; }

fail() {
  echo "[llamero-llamacpp] ERROR: $*" >&2
  if [ "$MODE" = "postinstall" ]; then
    echo "[llamero-llamacpp] llama.cpp setup was skipped; grammar mode will refuse to run until you do:" >&2
    echo "[llamero-llamacpp]     sh scripts/install_llamacpp.sh   (from lib/llamero/ when installed as a dependency)" >&2
    exit 0
  fi
  exit 1
}

if [ "${LLAMERO_SKIP_LLAMACPP:-0}" = "1" ]; then
  log "LLAMERO_SKIP_LLAMACPP=1 - skipping pinned llama.cpp install"
  exit 0
fi

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
SUPPORT_FILE="$SCRIPT_DIR/../src/llamacpp/support.cr"
[ -f "$SUPPORT_FILE" ] || fail "cannot find $SUPPORT_FILE (is this script inside the llamero shard?)"

TAG=$(sed -n 's/^ *PIN_TAG *= *"\([^"]*\)".*/\1/p' "$SUPPORT_FILE")
COMMIT=$(sed -n 's/^ *PIN_COMMIT *= *"\([^"]*\)".*/\1/p' "$SUPPORT_FILE")
[ -n "$TAG" ] && [ -n "$COMMIT" ] || fail "could not parse PIN_TAG/PIN_COMMIT from $SUPPORT_FILE"
SHORT_COMMIT=$(printf '%s' "$COMMIT" | cut -c1-7)

ROOT="${LLAMERO_HOME:-$HOME/.llamero}"
DEST="$ROOT/llamacpp/$TAG"
BINARY="$DEST/bin/llama-completion"

if [ "$FORCE" != "1" ] && [ -x "$BINARY" ]; then
  if "$BINARY" --version 2>&1 | grep -q "$SHORT_COMMIT"; then
    log "pinned llama.cpp $TAG ($SHORT_COMMIT) already installed at $BINARY"
    exit 0
  fi
  log "binary at $BINARY does not match pin $TAG ($SHORT_COMMIT); rebuilding"
fi

command -v git >/dev/null 2>&1 || fail "git is required to fetch the pinned llama.cpp source"
command -v cmake >/dev/null 2>&1 || fail "cmake is required to build the pinned llama.cpp (brew install cmake / apt install cmake)"
command -v cc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || fail "a C/C++ compiler is required to build the pinned llama.cpp"

WORKDIR=$(mktemp -d "${TMPDIR:-/tmp}/llamero-llamacpp.XXXXXX") || fail "mktemp failed"
cleanup() { rm -rf "$WORKDIR"; }
trap cleanup EXIT INT TERM

log "fetching llama.cpp $TAG (pinned commit $COMMIT)"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/ggml-org/llama.cpp "$WORKDIR/llama.cpp" \
  || fail "git clone of llama.cpp tag $TAG failed (network?)"

HEAD=$(git -C "$WORKDIR/llama.cpp" rev-parse HEAD)
[ "$HEAD" = "$COMMIT" ] || fail "tag $TAG resolved to $HEAD, expected pinned commit $COMMIT - refusing to build an unpinned tree"

# CPU-only, static, no tests/server: one self-contained binary, reproducible
# across macOS/Linux. Metal/CUDA variants are a later, deliberate pin change.
CMAKE_FLAGS="-DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DGGML_METAL=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF"

log "configuring (this builds from source; a few minutes on first install)"
cmake -S "$WORKDIR/llama.cpp" -B "$WORKDIR/build" $CMAKE_FLAGS >"$WORKDIR/cmake_configure.log" 2>&1 \
  || fail "cmake configure failed (log: $WORKDIR/cmake_configure.log)"

JOBS=$( (command -v sysctl >/dev/null 2>&1 && sysctl -n hw.ncpu) || (command -v nproc >/dev/null 2>&1 && nproc) || echo 4)
log "building llama-completion with $JOBS jobs"
cmake --build "$WORKDIR/build" --target llama-completion -j "$JOBS" >"$WORKDIR/cmake_build.log" 2>&1 \
  || fail "cmake build failed (log: $WORKDIR/cmake_build.log)"

BUILT="$WORKDIR/build/bin/llama-completion"
[ -x "$BUILT" ] || fail "build finished but $BUILT is missing"

"$BUILT" --version 2>&1 | grep -q "$SHORT_COMMIT" || fail "built binary does not report pinned commit $SHORT_COMMIT"

mkdir -p "$DEST/bin" || fail "cannot create $DEST/bin"
cp "$BUILT" "$BINARY" || fail "cannot install binary to $BINARY"
chmod +x "$BINARY"

cat > "$DEST/BUILD_INFO.json" <<EOF
{
  "tag": "$TAG",
  "commit": "$COMMIT",
  "binary": "llama-completion",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "cmake_flags": "$CMAKE_FLAGS",
  "host": "$(uname -sm)"
}
EOF

log "installed pinned llama.cpp $TAG ($SHORT_COMMIT) -> $BINARY"
exit 0
