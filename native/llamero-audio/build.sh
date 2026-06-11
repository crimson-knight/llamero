#!/bin/bash
# Builds the Swift audio bridge dylib that src/native/audio_bridge.cr dlopens.
#
# Unlike the MLX bridge there is no metallib step: FluidAudio runs its models
# through CoreML on the Neural Engine, so no Metal shaders are compiled.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
swift build -c "$CONFIG"

PRODUCTS=".build/$CONFIG"
DYLIB="$PRODUCTS/libLlameroAudioBridge.dylib"
if [ ! -f "$DYLIB" ]; then
  echo "error: build did not produce $DYLIB" >&2
  exit 1
fi

# Install to ~/.llamero/lib so consuming projects find the bridge from any
# working directory (AudioFFIBridge.discover_library_path checks there).
INSTALL_DIR="$HOME/.llamero/lib"
mkdir -p "$INSTALL_DIR"
cp "$DYLIB" "$INSTALL_DIR/libLlameroAudioBridge.dylib"

echo "bridge:    $DYLIB"
echo "installed: $INSTALL_DIR/libLlameroAudioBridge.dylib"
echo "Verify with the audio test (from the llamero repo or lib/llamero):"
echo "  crystal run examples/native_audio_test.cr -- /path/to/audio.wav"
