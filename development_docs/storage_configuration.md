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

## FluidAudio 0.15.2 directory support

Pinned source: `native/llamero-audio/Package.resolved` resolves
`FluidInference/FluidAudio` revision
`7f963cdc43ba89c5993654f1e138047d517a818d`.

Supported and plumbed:

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

Not cleanly supported:

- English Kokoro text-to-speech still uses `G2PModel.shared` for text to IPA.
  `G2PModel.loadIfNeeded` reads from
  `TtsCacheDirectory.ensure()/Models/kokoro`, which is
  `~/.cache/fluidaudio/Models/kokoro` on macOS. There is no public constructor,
  directory setter, or env var for this singleton.
- `KokoroAneManager.initialize` intentionally calls
  `KokoroAneResourceDownloader.ensureG2PAssets(directory: nil)` because the
  shared G2P singleton cannot see a caller-supplied directory. Passing the
  custom directory there would download assets to the app root and still fail
  when `G2PModel.shared` loads.

Upgrade or patch needed for full audio relocation:

1. FluidAudio should expose a configurable TTS cache root, or make
   `G2PModel` injectable/configurable by URL.
2. `KokoroAneManager` should pass its directory through to G2P asset download
   and phonemization when the G2P model can honor that path.
3. After that, `AudioRuntime` can guarantee that `speak` text synthesis uses
   only `Llamero.storage_root/audio_models`.

Do not use symlinks as a workaround; they hide the ownership boundary and make
app data cleanup ambiguous.
