#!/bin/bash
# Builds the Swift MLX bridge dylib that src/native/mlx_bridge.cr dlopens.
#
# Two-step build because command-line SwiftPM cannot compile Metal shaders:
#   1. swift build      -> libLlameroMLXBridge.dylib (fast incremental builds)
#   2. xcodebuild       -> mlx.metallib (only when missing/stale)
#
# MLX locates its Metal kernels at runtime by searching for mlx.metallib next
# to the binary containing the MLX code (see mlx/backend/metal/device.cpp),
# so the metallib is colocated with the dylib. The Metal toolchain is a
# separate Xcode component; install once with:
#   xcodebuild -downloadComponent MetalToolchain
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

PRODUCTS=".build/$CONFIG"
DYLIB="$PRODUCTS/libLlameroMLXBridge.dylib"
if [ ! -f "$DYLIB" ]; then
  echo "error: build did not produce $DYLIB" >&2
  exit 1
fi

METALLIB_SRC=".build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
if [ ! -f "$METALLIB_SRC" ]; then
  echo "Compiling Metal shaders via xcodebuild (one-time, slow)..."
  xcodebuild build -scheme llamero-mlx -destination 'platform=macOS,arch=arm64' \
    -configuration Release -derivedDataPath .build/xcode -skipMacroValidation -quiet
fi

cp "$METALLIB_SRC" "$PRODUCTS/mlx.metallib"

# Install to the configured storage root so consuming projects find the
# bridge from any working directory (MLXBridge.discover_library_path checks
# this lib directory).
INSTALL_ROOT="${LLAMERO_HOME:-$HOME/.llamero}"
INSTALL_DIR="$INSTALL_ROOT/lib"
mkdir -p "$INSTALL_DIR"
cp "$DYLIB" "$INSTALL_DIR/libLlameroMLXBridge.dylib"
cp "$PRODUCTS/mlx.metallib" "$INSTALL_DIR/mlx.metallib"

echo "bridge:    $DYLIB"
echo "metallib:  $PRODUCTS/mlx.metallib"
echo "installed: $INSTALL_DIR/libLlameroMLXBridge.dylib (+ mlx.metallib)"
echo "Verify with the smoke test (from the llamero repo or lib/llamero):"
echo "  crystal run examples/native_smoke_test.cr"
