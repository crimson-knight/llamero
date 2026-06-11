# Llamero Multimodal Roadmap: Vision, Speech-to-Text, Text-to-Speech

**Status:** Architecture proposal (researched 2026-06-11, ecosystem verified)
**Track:** Extends the native MLX track ([roadmap](native_mlx_roadmap.md),
[architecture](native_mlx_architecture.md)) with eyes, ears, and a voice.

## Vision

A Crystal application should be able to run a complete conversational loop on
Apple Silicon with no cloud dependency:

```
mic ──> VAD/end-of-utterance ──> STT (Parakeet) ──> text
                                                      │
webcam/screenshots ──> VLM ──────────────> resident LLM + adapters
                                                      │
speaker <── TTS (Kokoro/Marvis) <── sentence-chunked response
```

This is the substrate for voice assistants, dictation apps that talk back
(Scribe's missing half), and avatar-style agents that can see a webcam feed,
read documents from screenshots, hear the user, think with adapter-augmented
local models, and speak the reply.

## What the ecosystem provides today (verified June 2026)

**Vision:** `mlx-swift-lm` — the exact package our existing bridge wraps —
ships **MLXVLM** alongside MLXLLM. Same `ModelContainer`/`UserInput`/
`generate` machinery; `UserInput` accepts image attachments
(`.image(.url(...))`), processors handle resizing/normalization and inject
model-specific image tokens. Supported families include `gemma3`, `paligemma`,
`idefics3`, `smolvlm` (plus qwen-family, excluded below). Community work
(e.g. `VincentGourbin/gemma-4-swift-mlx`) demonstrates Gemma 4 multimodal
(text+vision+audio) natively on MLX Swift.

**Speech-to-text — Whisper is NOT required.** NVIDIA Parakeet runs natively
on Apple Silicon two ways:

| | FluidAudio (`FluidInference/FluidAudio`) | mlx-audio-swift (`Blaizzy/mlx-audio-swift`) |
|---|---|---|
| Runtime | CoreML on the **Apple Neural Engine** | MLX on the GPU |
| Parakeet | TDT v3 0.6B (25 EU languages + ja), TDT v2 (en), **EOU 120M streaming with end-of-utterance detection** | Parakeet in `MLXAudioSTT` |
| Extras | Silero VAD, speaker diarization (LS-EEND/Sortformer/Pyannote), Kokoro + PocketTTS TTS | TTS (`MLXAudioTTS`: Marvis, Orpheus, Soprano, Pocket...), VAD, codecs |
| Performance | ~190x real-time on M4 Pro | (younger project, v0.1.x) |
| License | Apache 2.0 | MIT |
| Maturity | Production SDKs (React Native/Rust wrappers exist) | Active, early |

**Text-to-speech:** Kokoro-82M (9 languages, parallel synthesis) and PocketTTS
(streaming, voice cloning) via FluidAudio on the ANE; Marvis/Orpheus/Soprano
via mlx-audio-swift on MLX.

## Model sourcing policy

Chinese-origin model families are excluded from llamero defaults and
recommendations (Qwen-VL/Qwen3-TTS/Qwen3-ASR, GLM-ASR, MOSS-TTS, SenseVoice,
Paraformer). Blessed defaults: **Gemma** (vision+language), **Parakeet**
(NVIDIA, STT), **Kokoro** (Apache 2.0, TTS), **Marvis** (TTS, expressive
option). The architecture keeps model choice configurable; this policy sets
defaults, not hard limits.

## Architecture decision: one pattern, two bridges

Keep the proven native-track pattern exactly: Swift package → C ABI dylib →
`dlopen` from Crystal → JSON event frames → callbacks on the calling thread →
mock bridge fallback so specs run anywhere → Crystal owns all model downloads
where the backend allows it.

1. **Vision extends the existing LLM bridge** (`native/llamero-mlx`). MLXVLM
   is the same dependency, the same container API, the same resident-model
   semantics. No new dylib.
2. **Audio is a new bridge** (`native/llamero-audio` →
   `libLlameroAudioBridge.dylib`). Different dependency graph (FluidAudio /
   CoreML), different lifecycle (always-on streaming vs request/response),
   and apps that only chat should not pay for audio frameworks.

**v1 audio backend: FluidAudio.** Deciding factor: it runs STT/VAD/TTS on the
**Neural Engine**, leaving the GPU entirely to the resident LLM/VLM. In the
avatar loop everything runs concurrently — transcription must not steal
compute from generation. It is also the most production-proven Parakeet on
Apple hardware (it is what powers the fast SuperWhisper-class experiences).
mlx-audio-swift is the MLX-native alternative; the C ABI below is
backend-agnostic so it can become a second backend (runtime config
`"backend": "fluid" | "mlx"`) without Crystal API changes. Caveat: FluidAudio
downloads its CoreML models from its own Hugging Face repos through its Swift
API — the "Crystal owns downloads" rule is relaxed for the audio bridge in v1
(the deadlock that forced that rule was specific to the Swift HF hub client's
main-queue hop; verify FluidAudio's downloader from a non-Swift host early,
and pin a fallback of pre-downloading model files Crystal-side if it hangs).

## Track A: Vision (VLM)

### Bridge changes (`native/llamero-mlx`)

- `LoadRequest` gains nothing — but load detects the model kind from
  `config.json` (`model_type`) and routes through the VLM factory/registry
  when the architecture is a VLM. One session = one model, vision-capable or
  not, same residency invariants (`load_count`, adapter hot-swap).
- `GenerateRequest.messages[]` entries gain optional
  `"images": ["/abs/path.jpg", ...]` (and later `"videos"`). The bridge maps
  them to `UserInput` image attachments. Image *paths only* — Crystal owns
  files; no byte buffers across the ABI in v1.
- New error code `vision_not_supported` when images are sent to a text-only
  model (honest rejection, session stays alive).

### Crystal surface

```crystal
runtime = Llamero::Native::MLXRuntime.new(model_id: "<gemma VLM, 4-bit>")
session = runtime.start_session
session.load_model

response = session.chat([
  Llamero::Message.user("What is happening in this picture?",
    images: [Path["~/Desktop/webcam_frame.jpg"]]),
])
```

- `Llamero::Message` gains an optional `images : Array(Path)` (empty default;
  cloud clients ignore it in v1 or raise clearly).
- `chat_structured` works unchanged — schema-prompted JSON about an image is
  the document-reading use case ("extract the table from this screenshot").
- Webcam/screen capture is the app's job (v1); llamero consumes image files.

### Success criteria

- A Gemma-family VLM answers questions about a local image file from Crystal.
- Text-only sessions are unaffected (`config.json` routing is transparent).
- Structured output parses from an image-grounded response.
- Adapter training still works on VLM bases (text-side LoRA).

## Track B: Audio (STT + TTS)

### New bridge: `native/llamero-audio`

Swift package depending on FluidAudio, exposing:

```c
typedef void (*llamero_event_callback)(const char *json_event, void *user_data);

int64_t llamero_audio_runtime_create(const char *json_config); // backend, model choices
void    llamero_audio_runtime_free(int64_t runtime);

// STT - one-shot file transcription
int32_t llamero_audio_transcribe_file(int64_t runtime, const char *json_request,
                                      llamero_event_callback cb, void *ud);

// STT - streaming: create a stream, push PCM frames, finish
int64_t llamero_audio_stream_create(int64_t runtime, const char *json_config);
int32_t llamero_audio_stream_push(int64_t stream, const float *samples, int32_t count,
                                  llamero_event_callback cb, void *ud);
int32_t llamero_audio_stream_finish(int64_t stream, llamero_event_callback cb, void *ud);
void    llamero_audio_stream_free(int64_t stream);

// TTS - text in, audio file out (v1), PCM chunk events (v2)
int32_t llamero_audio_speak(int64_t runtime, const char *json_request,
                            llamero_event_callback cb, void *ud);
```

Event frames (same envelope as the MLX bridge): `transcript_partial`,
`transcript_final` (text, segment timestamps, language), `utterance_end`
(from Parakeet EOU — this is what makes real-time dictation feel right),
`vad_state` (speech started/stopped), `speak_progress`, `speak_completed`
(output path, duration), `error`.

Same hard-won rules as the MLX bridge: all callbacks on the calling thread
via an EventSink queue; never depend on the main dispatch queue (verify
FluidAudio under a non-Swift host with the C-harness approach that caught
the HF downloader deadlock).

### Crystal surface

```crystal
audio = Llamero::Native::AudioRuntime.new   # Parakeet TDT v3 + Kokoro defaults

# One-shot: transcribe a file (Scribe's batch case)
result = audio.transcribe(Path["meeting.m4a"])
result.text       # full transcript
result.segments   # [{text, start_ms, end_ms}]

# Streaming: the app pushes mic samples; llamero streams text back
stream = audio.start_stream
stream.on_partial { |text| print "\r#{text}" }
stream.on_utterance { |utterance| handle(utterance.text) } # EOU-detected
stream.push(samples)   # Slice(Float32) from the app's capture layer
stream.finish

# TTS: the model talks back
spoken = audio.speak("I found three problems in that file.", voice: "af_heart")
spoken.path        # wav file to play; PCM streaming is v2
```

Mic/speaker I/O stays in the app in v1 (AVFoundation capture and playback are
app-framework concerns; Scribe already owns a capture pipeline). v2 can add
an optional capture/playback helper to the bridge if friction demands it.

### MockAudioBridge

Deterministic mock mirroring MockBridge: scripted transcripts, synthetic
timestamps, `speak` writes a small valid WAV header + silence. Specs for
stream lifecycle, event mapping, and error paths run on any platform.

### Success criteria

- Parakeet transcribes a file from Crystal faster than real time with correct
  text and timestamps, while an LLM generation runs concurrently (ANE + GPU).
- Streaming transcription emits partials and EOU-segmented utterances from
  pushed PCM.
- Kokoro speaks a sentence to a playable WAV in well under a second.
- The full echo loop runs in one Crystal process: WAV in → transcript →
  resident LLM reply → spoken WAV out.

## Phases

1. **VLM in the existing bridge** (smallest step, biggest unlock): model-kind
   routing, images in GenerateRequest, `Message#images`, smoke test with a
   Gemma VLM reading a screenshot.
2. **Audio bridge v1**: FluidAudio dep, file transcription + speak-to-file,
   AudioRuntime/MockAudioBridge + specs, CLI-style example
   (`examples/native_audio_test.cr` — record-or-load WAV → transcript →
   reply → spoken WAV).
3. **Streaming STT**: stream_create/push/finish, EOU events, live dictation
   example. This is the Scribe-upgrade milestone.
4. **The round-trip demo**: echo agent wiring all three tracks with the
   adapter system (a "voice + eyes" lab page in the Phase 4 desktop UI).
5. **v2 options**: PCM-streaming TTS (Marvis via mlx-audio-swift backend),
   diarization events, bridge-side capture helper, video input.

## Known issue: adapter training on Gemma 4 e-series

Verified 2026-06-11: training a LoRA adapter on `gemma-4-e2b-it-4bit`
converges (loss 8.2 → 0.048) and the adapter activates without error, but
generation is bit-for-bit unaffected — even verbatim training prompts at
temperature 0 produce base-model output. The identical pipeline passes 3/3
on dense `gemma-3-1b-it-4bit` and on Qwen3-0.6B, so the template,
tokenization, save format, and activation path are all sound. The adapter's
weight keys live under the multimodal wrapper
(`language_model.model.layers.*`, attention projections only).

Working hypothesis: the e-series MatFormer-style elastic architecture
(per-layer embeddings, KV-sharing across later layers) takes a different
effective path at inference than during training, so deltas trained on the
suffix layers are bypassed. Next steps when this gets picked up: dump
adapter-applied vs base logits inside the bridge for one prompt, check
upstream mlx-swift-lm gemma-4 implementation for train/inference divergence,
and test LoRA on *earlier* layers (`num_layers` covering non-KV-shared
layers). Until then: e-series for inference, dense models for training.

## Open questions

- Does FluidAudio's model downloader work under a non-Swift host process, or
  does it need the Crystal-side pre-download fallback? (Test first, like the
  HF hub deadlock.)
- Gemma 4's native audio input (it is text+vision+audio multimodal): does
  mlx-swift-lm expose it, and is "the LLM hears raw audio" ever preferable to
  Parakeet→text? (Likely complementary: Parakeet for transcription fidelity
  and timestamps; model-native audio for tone/paralinguistics later.)
- TTS voice identity for the avatar: Kokoro's fixed voices vs PocketTTS voice
  cloning vs Marvis — pick after listening tests.
- Should `AudioRuntime` and `MLXRuntime` share a session/event bus for the
  desktop lab UI, or stay independent until the UI phase forces the question?
