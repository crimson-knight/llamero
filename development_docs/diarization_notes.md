# Speaker Diarization Notes

**Date:** 2026-06-12
**Pinned dependency:** FluidAudio 0.15.2 (`native/llamero-audio/Package.resolved`, revision `7f963cdc43ba89c5993654f1e138047d517a818d`)

## FluidAudio Diarization Surface

FluidAudio 0.15.2 ships multiple diarization paths:

- `OfflineDiarizerManager`: best batch/file diarizer. It implements the pyannote community-1 style offline pipeline: powerset segmentation, fbank, WeSpeaker embeddings, PLDA/VBx clustering, and reconstruction into speaker windows.
- `LSEENDDiarizer`: streaming/end-to-end diarization, up to 10 speakers, lower-latency timeline output.
- `SortformerDiarizer`: streaming/end-to-end diarization, stronger speaker identity stability, limited to 4 speakers.
- `DiarizerManager`: legacy online pyannote/WeSpeaker path. FluidAudio docs mark it as slower and weaker for low-latency streaming than LS-EEND/Sortformer.

For llamero's one-shot file API, `OfflineDiarizerManager` is the right surface:

```swift
let config = OfflineDiarizerConfig()
let manager = OfflineDiarizerManager(config: config)
try await manager.prepareModels()

let result = try await manager.process(URL(fileURLWithPath: "meeting.wav"))

for segment in result.segments {
    print("\(segment.speakerId) \(segment.startTimeSeconds)s-\(segment.endTimeSeconds)s")
}
```

The exact output type is `DiarizationResult`, whose `segments` are `[TimedSpeakerSegment]`. Each segment has `speakerId`, `startTimeSeconds`, `endTimeSeconds`, `qualityScore`, and an embedding. `DiarizationResult.timings` can carry stage timings (`segmentationSeconds`, `embeddingExtractionSeconds`, `speakerClusteringSeconds`, etc.).

The file API `process(_ url: URL, progressCallback:)` uses `AudioSourceFactory.makeDiskBackedSource`, so large files are memory-mapped/streamed instead of fully materialized. The progress callback receives `(chunksProcessed, totalChunks)` after segmentation chunks.

## Model Loading, Size, and Compute

Offline model loading is handled by `OfflineDiarizerModels.load(...)`. It loads from `~/Library/Application Support/FluidAudio/Models/speaker-diarization-coreml` by default and downloads missing assets from Hugging Face through FluidAudio's `DownloadUtils` URLSession path.

The offline variant requires these assets from `FluidInference/speaker-diarization-coreml`:

- `Segmentation.mlmodelc`: about 5.7 MB
- `FBank.mlmodelc`: about 1.7 MB
- `Embedding.mlmodelc`: about 12.9 MB
- `PldaRho.mlmodelc`: about 0.2 MB
- `plda-parameters.json`: about 0.1 MB

Required offline download total is about 20.6 MB. The full HF repo is about 123 MB because it also contains legacy/online assets such as `pyannote_segmentation.mlmodelc` and `wespeaker_v2.mlmodelc`.

Compute placement in the pinned source:

- Offline segmentation, embedding, and PLDA Core ML models load with `MLComputeUnits.all`.
- FBank loads with `MLComputeUnits.cpuOnly`.
- The offline extractor explicitly prefetches arrays to the Neural Engine in hot paths.
- FluidAudio's README describes the speech models as optimized for ANE/background use. In practice, Core ML still owns scheduling under `.all`, so callers should expect ANE/CoreML contention if ASR and diarization run concurrently.

Observed on this M1 Max after the repo already had Parakeet models cached:

- First diarizer load/download during `examples/native_diarization_test.cr`: about 7.3s.
- Cached diarizer model load on the next process run: about 89ms.
- Cached run on a generated 17.92s two-speaker WAV: total diarized transcription wall time about 0.81s; ASR processing about 0.24s; diarizer processing about 0.29s.

## Combining Diarization and ASR

Parakeet ASR returns full text plus token timings. The bridge groups SentencePiece token timings into word-level spans:

```json
{"text": "meeting", "start_ms": 1200.0, "end_ms": 1560.0}
```

The offline diarizer returns speaker activity windows:

```json
{"speaker": "S1", "start_ms": 0.0, "end_ms": 6710.0}
```

The speaker-attributed transcript is built by assigning each ASR word span to the nearest diarizer speaker window. Words inside a speaker window have zero distance; words just outside a window, usually because ASR and diarizer boundaries differ slightly, attach to the nearest speaker window so the transcript does not drop tail words. The final public segments are:

```json
{"speaker": "S1", "start_ms": 0.0, "end_ms": 8080.0, "text": "Good morning..."}
```

The bridge also emits raw `word_segments` and raw diarizer `speaker_segments` so callers can inspect or re-align if they need a different policy.

## llamero Implementation

The Swift bridge now exports:

```c
int32_t llamero_audio_runtime_transcribe_diarized(
  int64_t runtime,
  const char *path,
  const char *config_json,
  llamero_event_callback callback,
  void *user_data
);
```

It follows the existing audio bridge contract:

- requests/config cross the ABI as strings;
- callback frames are JSON event objects;
- async FluidAudio work pushes into `EventSink`;
- `EventSink.drain` invokes callbacks synchronously on the FFI calling thread;
- no main dispatch queue dependency.

The runtime owns resident `OfflineDiarizerModels`. Each diarized transcription creates a fresh `OfflineDiarizerManager(config:)` and initializes it with the cached models. This keeps model load/download one-time per runtime while allowing per-call diarization config:

- `speaker_count`
- `min_speakers`
- `max_speakers`
- `clustering_threshold`

Crystal API:

```crystal
audio = Llamero::Native::AudioRuntime.new
result = audio.transcribe_diarized(Path["meeting.wav"], speaker_count: 2)

result.text
result.segments          # Array(DiarizedTranscriptSegment)
result.word_segments     # raw ASR word timings
result.speaker_segments  # raw diarizer speaker windows
```

New bridge events:

- `diarizer_model_load_started`
- `diarizer_model_load_progress`
- `diarizer_model_loaded`
- `diarization_progress`
- `diarized_transcript_final`

## Multi-Audio-Model Architecture Assessment

### Two AudioRuntime instances with different Parakeet versions

This is supported by the current handle design. `llamero_audio_runtime_create` returns an opaque handle whose `AudioRuntimeBox` owns its own config, `AsrManager`, decoder-layer count, TTS manager, streaming EOU cache, and diarizer model cache. Two Crystal `AudioRuntime` objects can therefore keep separate v2/v3 Parakeet stacks alive without handle collisions.

The comfort limit is memory and Core ML scheduling, not API isolation. Parakeet v2 and v3 are separate Core ML model sets; keeping both loaded avoids reload latency but increases resident memory. Calls should be serialized or scheduled intentionally when both runtimes target ANE-heavy work.

### Diarizer alongside ASR for meeting mode

This is feasible and now implemented for file mode. A single runtime can keep Parakeet ASR models and offline diarizer models resident. The bridge runs ASR and diarization sequentially inside `transcribe_diarized`, then aligns words to speaker windows.

For meeting mode, this is comfortable for post-recording or chunk-finalization passes. For live streaming, use the existing Parakeet EOU stream for live partials and run offline diarization over finalized audio chunks or the complete recording. Running ASR and offline diarization concurrently can contend for ANE/CoreML resources because both use Core ML `.all`/ANE-optimized models.

### Switching models at runtime

Current model switching means creating another `AudioRuntime` with a different config or closing/recreating a runtime. The runtime-handle design isolates stacks cleanly, so app-level switching can be implemented as a small pool of named `AudioRuntime` instances, similar in spirit to `Native::ModelPool` for MLX models.

What is missing for "comfortable" switching is a first-class audio model pool and memory policy:

- no API to unload just ASR v2 while keeping diarizer/TTS loaded;
- no per-runtime memory accounting;
- no scheduler for ANE/CoreML contention across ASR, TTS, diarization, and multiple runtimes;
- no shared ASR model cache across runtime handles.

Recommended future fix: add `Llamero::Native::AudioModelPool` with named members, explicit close/unload controls, and an optional serial CoreML work queue for ANE-heavy tasks. The current opaque-handle bridge already supports this cleanly; it just needs Crystal orchestration and optional bridge-side unload hooks.

## Verification Snapshot

Real on-device run:

```text
crystal run examples/native_diarization_test.cr
generated test audio: .../two-speaker-meeting.wav
speaker A voice: Samantha, speaker B voice: Daniel
bridge: fluid_audio (native/llamero-audio/.build/release/libLlameroAudioBridge.dylib)
audio 17.92s processed in 0.79s (asr 0.23s, diarizer 0.23s)
S2 0.0s-8.08s: Good morning...
S1 8.48s-17.92s: Thanks...
```
