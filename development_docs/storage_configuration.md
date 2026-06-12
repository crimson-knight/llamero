# Storage Configuration Notes

## llamero storage root

Default storage remains `~/.llamero`. Consuming apps can move llamero-owned
artifacts at boot:

```crystal
Llamero.storage_root = Path.home.join(".scribe")
```

`LLAMERO_HOME=/path/to/root` is the environment alternative. Programmatic
configuration wins over the environment. The root controls:

- `models/` for `Llamero::Native::ModelDownloader`
- `adapters/` for default `ModelSession#train_adapter` output
- `lib/` for MLX and audio bridge dylib discovery
- `audio_models/` for the audio bridge when the storage root is configured

The build scripts also honor `LLAMERO_HOME` for bridge installs. Programmatic
runtime configuration cannot affect a shell script that already ran, so app
projects that want bridge dylibs under their own root should set
`LLAMERO_HOME` while running `native/llamero-mlx/build.sh` or
`native/llamero-audio/build.sh`.

## FluidAudio fork directory support

Pinned source: `native/llamero-audio/Package.swift` points at the
`crimson-knight/FluidAudio` `configurable-storage-paths` branch, based on
upstream `v0.15.2`.

Supported and plumbed:

- `FluidAudio.modelsDirectoryOverride` accepts one caller-owned model root.
  The audio bridge sets it from the existing runtime JSON `models_dir`, which
  llamero derives from `<storage_root>/audio_models` when storage is configured.
- `AsrModels.downloadAndLoad(to:)` accepts a custom Parakeet model directory.
  llamero passes `<storage_root>/audio_models/<parakeet repo folder>` for the
  v2/v3 one-shot ASR path.
- `OfflineDiarizerModels.load(from:)` accepts a custom base models directory.
  llamero passes `<storage_root>/audio_models`.
- `StreamingEouAsrManager.loadModels(to:)` accepts a custom base directory.
  llamero mirrors FluidAudio's current default layout by passing
  `<storage_root>/audio_models/parakeet-eou-streaming`.
- `KokoroAneManager(directory:)` accepts a custom directory for the main
  Kokoro ANE model chain and voice packs. llamero passes
  `<storage_root>/audio_models`.
- The fork also routes Kokoro English G2P assets through the same directory:
  `KokoroAneManager.initialize` passes its directory to
  `KokoroAneResourceDownloader.ensureG2PAssets`, and `G2PModel.shared` loads
  from that directory instead of a fixed TTS cache.

With a configured storage root, `AudioRuntime#transcribe`,
`AudioRuntime#transcribe_diarized`, streaming ASR, and `AudioRuntime#speak`
should only create or read FluidAudio model artifacts under
`<storage_root>/audio_models`.

Do not use symlinks as a workaround; they hide the ownership boundary and make
app data cleanup ambiguous.
