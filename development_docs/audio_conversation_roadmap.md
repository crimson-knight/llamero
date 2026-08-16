# Audio: meeting-notes + conversational exchange roadmap

**Captured 2026-06-21** from a scoping session with the owner. This is the
execution spec for turning llamero's audio building blocks into two real
product experiences on **macOS** (Apple Silicon, desktop):

1. **Meeting-notes mode** — the agent "joins" a Teams/Zoom call *without*
   integrating into those apps: it captures the user's **mic** and the
   **system audio** and produces a durable, speaker-attributed transcript.
   The cheap, reliable diarization signal is the channel itself: **mic = the
   user, system audio = everyone else.**
2. **Conversational exchange** — a smooth listen → think → speak loop with low
   time-to-first-audio and **barge-in** (the user can interrupt mid-speech).

It supersedes the audio portions of `multimodal_roadmap.md` Phases 3–5 with a
concrete, code-anchored plan. Capture target is **macOS 14.4+**.

---

## 1. Ground truth (what exists today, verified against the code)

| Capability | State | Anchor |
|---|---|---|
| File transcription (Parakeet) + word timestamps | **Verified on-device** 2026-06-11 (59× RT, 94% conf) | `audio_runtime.cr#transcribe` |
| Offline speaker diarization | **Verified on-device** 2026-06-12 (2-speaker WAV, correct split) | `audio_runtime.cr#transcribe_diarized`, `diarization_notes.md` |
| TTS (Kokoro) → one WAV file | **Verified on-device**; whole-utterance, not streaming | `audio_runtime.cr#speak`, `Bridge.swift#llamero_audio_speak` (917-984) |
| Streaming STT (Parakeet EOU) | **Implemented + spec-covered; NOT yet device-verified** | `audio_stream.cr`, `Bridge.swift#stream_*` (1101-1277) |
| Mock bridge + `real_bridge?` gating | Works (specs pass anywhere) | `mock_audio_bridge.cr`, `audio_runtime.cr#real_bridge?` |

**Missing for the two experiences (the work this doc plans):**

- Audio **capture** (mic + system audio) — and deliberately so: capture stays
  app-side. We only need to *recommend* the macOS approach (§3).
- Audio **playback** — also app-side; llamero emits PCM, the app plays it.
- **Durable** transcription (crash-safe journal). Today llamero persists
  **nothing** — a crash loses the in-memory transcript. This is the owner's
  recurring pain.
- **Streaming TTS** (per-sentence PCM emission for low latency).
- **VAD** exposure (FluidAudio ships Silero VAD; not surfaced).
- **Barge-in** / cancel (no way to stop speech mid-utterance).
- **Source-labeled** streams (tag utterances mic vs system).
- Live/streaming **diarization** (only offline/file diarization exists).

---

## 2. Boundary: who owns what

The deliberate seam (`multimodal_roadmap.md`: "mic/speaker I/O stays in the
app") holds. Refined for these two experiences:

| Concern | Owner | Why |
|---|---|---|
| Mic capture, system-audio capture, device/permission UX | **App** | Platform-specific (Core Audio taps / AVAudioEngine); macOS-only |
| Audio **playback** (queue PCM to speakers) | **App** | AVAudioEngine/AVAudioPlayerNode; OS-specific |
| Transcription (batch + streaming) | **llamero** | Already shipped |
| **Source-labeled** streaming + utterance attribution | **llamero (new)** | Natural home for the mic=me/system=them trick |
| **Durable journal** of finalized utterances | **llamero (new)** | Write once, every app inherits crash-safety |
| **Streaming TTS** (per-sentence PCM events) | **llamero (new)** | Bridge-side, reuses Kokoro |
| **VAD** signal | **llamero (new)** | Surface FluidAudio Silero VAD |
| **Barge-in/cancel** primitive | **llamero (new)** + app playback stop | llamero stops synth; app stops playback |
| Turn-taking state machine, the back-and-forth glue | **llamero convenience + app** | A `ConversationSession` helper, app drives I/O |

---

## 3. Capture (app-side, macOS) — the recommended approach

**Decision: native Core Audio process taps, no bundled driver.** Researched
2026-06-21; full reasoning preserved here so the app implementation targets the
right thing.

- **Primary: Core Audio process taps** (`AudioHardwareCreateProcessTap` +
  aggregate device), macOS **14.4+**. No driver install, no admin password, no
  Audio MIDI Setup, no reboot. One-time TCC "audio recording" permission
  (quiet purple-dot indicator). Can translate a PID → `AudioObjectID`
  (`kAudioHardwarePropertyTranslatePIDToProcessObject`) to tap **only the
  meeting app** and exclude our own output. Build an aggregate device
  (`kAudioAggregateDeviceTapListKey`) to merge {tap + mic} into one
  synchronized device, OR keep them as **two streams** (preferred here — gives
  free speaker attribution).
- **Mic:** `AVAudioEngine` tap on `inputNode` → `AVAudioPCMBuffer` Float32.
  Separate `NSMicrophoneUsageDescription` permission.
- **Fallback: ScreenCaptureKit audio** (`SCStream`, `capturesAudio = true`),
  macOS 13+, only if we must support 13.x. Captures system audio with just
  Screen Recording permission — **but** Sequoia re-confirms that permission
  periodically and we can't disable it, which breaks "approve once." Avoid as
  primary.
- **Do NOT ship BlackHole or a DriverKit dext.** BlackHole is GPL-3.0
  (incompatible with a proprietary paid app without a commercial license from
  Existential Audio). A DriverKit audio extension needs an Apple-granted
  entitlement, a System-Settings approval prompt, and is barred from the App
  Store. The native taps achieve the owner's "install → approve once → we
  configure it" goal *without* any of that.

**End-user flow (recommended path):** download `.dmg` → drag to Applications →
launch → on first "Start recording" approve two one-time prompts (system-audio
+ microphone) → recording works on the first meeting. No device to configure.

**Top capture risks:** (1) permission denial is *invisible* — denied taps
return all-zero buffers and there's no public API to query authorization; the
app must detect silence and guide the user; (2) OS floor 14.4; (3) taps are a
newish API — revalidate each macOS release; (4) system-audio capture grabs all
output (notifications/music) and has no echo cancellation — tap the meeting
process specifically and/or do AEC. (5) Output samples are whatever the tap
negotiates (commonly 48 kHz) — the app must resample to **16 kHz mono Float32**
before `stream.push` (llamero's ASR contract).

> llamero does not implement capture. This section is the spec the app (or a
> future optional `v2` bridge capture helper) builds to.

---

## 4. Workstream 1 — streaming STT device-verification + durable journal

**Goal:** convert "pending verification" into a real result, and end the
crash-loses-dictation pain. Self-contained, no app dependency, highest
priority.

### 4a. On-device verification (no simulator needed)
`examples/native_dictation_test.cr` is a **native Crystal CLI** that simulates a
mic by reading a 16 kHz mono WAV in chunks and pushing them through
`start_stream`. It runs as a host process on the Mac against the built dylib —
**no iOS simulator, no Happy Coach**. This decouples engine verification from
the app's UI blocker.

- Build: `cd native/llamero-audio && ./build.sh`.
- Generate input: `say -o /tmp/dictation.wav --data-format=LEF32@16000 "First sentence. [[slnc 2000]] Second sentence."`
- Run: `crystal run examples/native_dictation_test.cr -- /tmp/dictation.wav`
- **Acceptance:** partials grow during each utterance; `utterance_end` fires at
  each silence gap with sane timestamps; `finish` returns the full transcript;
  measure partial latency and EOU quality at the default 1280 ms debounce.
  Record numbers in this doc's "Verification log" (§9).

### 4b. Durable journal (opt-in, crash-safe)
**Design:** an append-on-finalize journal so a crash loses at most the
in-flight (not-yet-EOU) phrase.

- API: `audio.start_stream(journal: Path["~/.../session.jsonl"])` (nil = off,
  preserving current behavior).
- On every finalized utterance (and on `finish`'s trailing utterance), append
  one JSONL line `{seq, text, start_ms, end_ms, source?, created_at}` and
  **fsync** (or fsync every N lines / 1 s, configurable — durability vs IO).
- The append point is the utterance dispatch already in
  `audio_stream.cr#dispatch` (156-169) → on `UtteranceEndEvent`, write the
  line before invoking user listeners. Keeps it bridge-agnostic (works on mock
  too) and testable without the dylib.
- Recovery: `Llamero::Native::TranscriptJournal.read(path) : Array(Utterance)`
  to resume/rebuild after a crash.
- **Optional raw-audio journaling** (`journal_audio: true`): also append each
  pushed chunk to a `.f32` sidecar so a finalized recording can be
  re-transcribed at higher accuracy later (the EOU 120 M model trades accuracy
  for latency; a TDT v3 re-pass over the saved audio is the quality path the
  roadmap recommends). Defer if it complicates v1.
- **Acceptance (spec, mock-only):** push scripted utterances, assert the JSONL
  exists and is complete after each finalize; simulate a mid-stream crash
  (drop the stream without `finish`) and assert the journal still holds every
  finalized utterance. Specs must pass with no dylib (`CLAUDE.md` rule).

---

## 5. Workstream 2 — meeting mode (dual-channel, diarized, durable)

**Goal:** the capability the owner is most excited about. Builds on WS1.

### 5a. Source-labeled streams (the mic=me/system=them trick)
- `audio.start_stream(source: "mic")` and `start_stream(source: "system")` —
  add an optional `source : String?` carried in the stream's config and
  stamped onto every emitted utterance.
- Bridge: thread the label through `AudioStreamBox`; `emitStreamUtterance`
  (`Bridge.swift` 1073-1092) adds `"source"` to the `utterance_end` /
  `transcript_final` frames.
- Crystal: add `source : String?` to `UtteranceEndEvent` (`audio_events.cr`
  216-227) and `Utterance` (`audio_stream.cr` 10-17); pass through dispatch.
- **Two concurrent streams on one runtime** already works (the runtime owns the
  EOU manager cache); validate ANE contention under two live streams, and if it
  bites, allow two `AudioRuntime`s (handle design isolates stacks cleanly —
  `diarization_notes.md`).

### 5b. `MeetingSession` convenience (merge the timeline)
A thin helper that owns two labeled streams and merges their utterances into one
time-ordered, speaker-attributed transcript: mic utterances → "Me", system
utterances → "Them". Writes through the WS1 journal. The app feeds each stream
its channel's resampled samples.

### 5c. Multi-party on the system channel
When several remote people share the system channel, run **offline
`transcribe_diarized`** over the finalized system-channel audio (or per
chunk-finalization pass) to split "Them" into S1/S2/… — `transcribe_diarized`
already exists and is verified. Live diarization stays out of scope (deferred).

- **Acceptance:** a scripted two-source session (mock) yields a merged
  transcript with correct `source` labels and ordering; a diarization pass over
  a 2-speaker system WAV (example, on-device) splits remote speakers.

---

## 6. Workstream 3 — smooth conversational exchange (streaming TTS + VAD + barge-in)

**Goal:** the "even, smooth, simultaneous" experience originally described.

### 6a. Streaming TTS (Kokoro, per-sentence)
Today `llamero_audio_speak` (`Bridge.swift` 917-984) splits text into sentence
chunks (`sentenceChunks`, 868-915) and the loop at **949-954 accumulates**
samples before writing one WAV. Change: **emit each chunk's PCM as it
completes** instead of (or in addition to) accumulating.

- New bridge entry `llamero_audio_speak_streaming` (or a `stream: true` flag on
  the speak request) — keep whole-file `speak` for non-streaming callers.
- Per chunk, after `synthesizeDetailed`, `sink.emit(["event": "speech_chunk",
  "chunk_index": i, "pcm_base64": <int16 LE>, "sample_rate": 24000,
  "is_final": false, "duration_ms": …])`; emit a final `speak_completed` after
  the last chunk. (EventSink/emit pattern: `Bridge.swift` 276-346.)
- PCM transport: **base64 int16** in the event keeps it diskless and simple
  (~1-3 s of 24 kHz mono per sentence is small). Fallback if base64 bloat
  matters: write each chunk to a temp WAV and emit the path (reuses
  `AudioWAV`).
- Crystal: add `SpeechChunkEvent` to `audio_events.cr` dispatch (67-103,
  template = `SpeakCompletedEvent` 283-299) and a `speak_streaming(text){ |chunk| }`
  API yielding decoded PCM chunks.
- App: schedule each chunk onto a single persistent `AVAudioPlayerNode` so
  playback is gapless; **TTFA = synth time of sentence 1 only.** Optional
  polish: ~60-120 ms inter-sentence silence + few-ms edge fades to hide
  per-sentence prosody resets.
- Kokoro stays on the **ANE** → no GPU contention with the MLX LLM. (Marvis /
  mlx-audio reconsidered only if a future spike shows a real quality win;
  they're GPU-bound and Swift-immature — see research note in §10.)
- **Acceptance:** on a multi-sentence paragraph (example, on-device), first
  `speech_chunk` arrives in ≪ total synthesis time (target TTFA < ~400 ms for a
  short first sentence); chunks decode to valid PCM; concatenation equals the
  non-streaming WAV within tolerance.

### 6b. VAD exposure
Surface FluidAudio's **Silero VAD** through the bridge as a lightweight
"is-speech-now" signal (distinct from EOU = "phrase finished"). Used for
barge-in and for gating silence out of the ASR. Emit `speech_started` /
`speech_ended` events (or a VAD gate on the stream). Spec against mock with a
scripted speech/silence pattern.

### 6c. Barge-in / cancel
- A cancellable streaming-speak handle: `llamero_audio_speak_cancel(handle)`
  sets a flag the chunk loop checks between sentences; emit `speech_cancelled`
  and stop. Sentence-granularity stop is sufficient (≤ one sentence of
  overrun); the app stops its playback queue instantly on VAD `speech_started`.
- Net barge-in latency = app playback-stop (instant) + synth stop at next
  chunk boundary.
- **Acceptance:** start a long streaming utterance, fire cancel mid-stream,
  assert no chunks emit after the cancel boundary and `speech_cancelled` fires.

---

## 7. Workstream 4 — the integration guide + `ConversationSession`

The owner's original ask: "very clear documentation so an integrator can build
a back-and-forth audio exchange." Deliver once 1-3 land:

- `Llamero::Native::ConversationSession` — wires streaming STT → LLM chat →
  streaming TTS with barge-in, leaving capture/playback as two app callbacks.
  The smallest "turnkey" surface that stays honest about the app's two jobs.
- A `development_docs/audio_integration_guide.md` + a worked example
  (`examples/native_conversation_test.cr`) and, if it fits the skills model, a
  `voice` skill. The guide states plainly what the app must supply (capture,
  playback) and the macOS capture recipe from §3.

---

## 8. Sequencing & dependencies

```
WS1 (verify streaming STT + durable journal)   ← start here; no app dep
   │
   ├─► WS2 (meeting mode: labeled streams, MeetingSession, multi-party diarize)
   │
   └─► WS3 (streaming TTS → VAD → barge-in)     ← the "smooth exchange" cluster
              │
              └─► WS4 (ConversationSession + integration guide + example)
```

Rationale: WS1 is small, kills active data loss, and unblocks the device-verify
unknown. WS2 and WS3 are independent and can interleave. WS4 needs both.

**Repo discipline (`CLAUDE.md`):** every workstream ships mock-only specs that
pass with no dylib and no network; all real-inference verification lives in
`examples/` and is logged in §9. The C ABI is the compatibility boundary —
every new Swift export needs a matching `mlx_bridge`/`audio_bridge` change + a
`build.sh` rebuild.

---

## 9. Verification log

_(populated as each on-device check runs)_

- [x] **WS1 streaming STT — engine VERIFIED on-device 2026-06-21** (M1 Max,
  `examples/native_dictation_test.cr`). Continuous speech transcribes
  perfectly: "The quick brown fox jumps over the lazy dog near the river bank"
  → exact, 3.9 s audio in 1.4 s wall, 1 utterance. Streaming model load:
  ~2.2 s first run, ~165–450 ms cached. Partial hypotheses stream and grow
  correctly.
- [ ] **WS1 streaming STT — EOU segmentation: DEFECT FOUND, NOT passing.**
  On clips with long silences the streaming path fails two ways. Repro
  (`say --data-format=LEF32@16000`):
  - 2 s `[[slnc]]` gaps, long sentences → all text retained but merged into
    **1 utterance** (no EOU boundary fired).
  - 3.5 s `[[slnc]]` gaps, short words ("First. Second. Third.") → only
    **"first"** survived; "second"/"third" never appeared even as partials,
    and the single utterance's `end_ms` = full duration (emitted at finish, no
    mid-stream EOU).
  - Same clip + faint pink room-tone noise (ffmpeg `anoisesrc a=0.004`) →
    "first second" (third still dropped); still 1 utterance.
  Diagnosis: llamero's glue is sound (partials stream; the shift-step push loop
  + `takePendingUtterance`/`reset` is correct — `Bridge.swift` 1057–1067,
  1164–1186). The EOU **callback never fires** and the decoder **loses tail
  audio** across long/pure-silence regions → FluidAudio
  `StreamingEouAsrManager` behavior, below our boundary. Pure digital silence
  (`say [[slnc]]`) is unrealistic input — real mic audio always carries room
  tone — and noise partially recovers retention, so this may not reproduce
  with a live mic. **Next:** verify with a real microphone recording (needs
  hardware; can't run headless) and, if it persists, investigate FluidAudio's
  EOU/VAD on low-energy frames. Tracked as a known-issue task.
- [x] **WS1 journal crash-safety (spec): PASSING.** `transcript_journal_spec`
  + `audio_stream_spec` (43 examples, 0 failures on mock): finalized
  utterances are fsync'd before listeners fire; a stream abandoned without
  `finish` (crash) keeps every confirmed utterance; torn final line tolerated;
  seq resumes on reopen; source label stamped + journaled.
- [x] **WS2 labeled two-stream merge — VERIFIED on-device 2026-06-21**
  (`examples/native_meeting_test.cr`, two `say` voices). Samantha→mic→"Me",
  Daniel→system→"Them": 2 lines, correctly attributed by channel, merged
  transcript + crash-safe journal recovered 2 lines. Channel-as-speaker works
  as designed. Two concurrent streams → two resident streaming managers (2nd
  loads in ~100 ms; memory note, not a problem). Spec: `meeting_session_spec`
  (4 examples) on mock. Multi-party split of the "Them" channel reuses the
  already-verified offline `transcribe_diarized` (documented pattern, no new
  code).
- [x] **WS3 streaming TTS — VERIFIED on-device 2026-06-21**
  (`examples/native_streaming_tts_test.cr`). Per-sentence chunks: a 4-sentence
  reply emitted 4 `speech_chunk`s (one per sentence) with first audio at
  **2.2 s TTFA** while the rest synthesized — vs one 12 s blob before. Fix:
  added `streamingChunks` (one sentence per chunk) because `sentenceChunks`
  packs to 300 chars and made a short reply one chunk. Kokoro on ANE (no GPU
  contention). Spec: `streaming_speak_spec` (6 examples, mock).
- [x] **WS3 barge-in cancel — VERIFIED on-device 2026-06-21**
  (`examples/native_bargein_test.cr`). Cancelling after chunk 0 of a
  12-sentence reply stopped synthesis at 2/12 and `speak_streaming` returned
  nil. New `llamero_audio_speak_cancel` export + per-sentence cancel check.
- [x] **WS3 VAD — VERIFIED on-device 2026-06-21**
  (`examples/native_vad_test.cr`). Silero VAD loaded in ~1.6 s and split a
  6.3 s clip into 2 speech segments (0.16–2.92 s, 4.51–6.5 s) across a 1.5 s
  silence. **Bonus: VAD segmented the silence the EOU model could not** —
  confirms the VAD-gated-endpointing fix for issue #33. New
  `llamero_audio_vad_{create,push,free}` exports + `VadStream`. Spec:
  `vad_stream_spec` (6 examples, mock).
- [x] **WS4 full conversation loop — VERIFIED on-device 2026-06-21**
  (`examples/native_conversation_test.cr`). One Crystal process: spoken
  question → "what is the capital of france" → responder → reply streamed as 2
  sentence chunks. This is the roadmap's Phase-4 round-trip demo, now real.
  `ConversationSession` queues utterances and responds AFTER the stream call
  returns (no nested-FFI re-entrancy). Spec: `conversation_session_spec`
  (4 examples, mock). Integration guide: `audio_integration_guide.md`.

---

## 10. Open questions & risks

- **Permission denial is invisible** (capture, app-side) — must detect
  all-zero buffers and remediate. Highest functional risk for meeting mode.
- **ANE contention** when ASR + TTS + diarization (+ two streams) run
  concurrently — all use Core ML `.all`. May need the serial CoreML work queue
  / `AudioModelPool` proposed in `diarization_notes.md`.
- **Streaming TTS prosody seams** at sentence boundaries (Kokoro resets per
  call) — mitigations in §6a; acceptable for conversational use.
- **base64 PCM event size** vs temp-WAV-path tradeoff — decide during WS3 spike.
- **Marvis/mlx-audio** revisited only if Kokoro quality proves insufficient;
  they are GPU-bound (contend with the LLM) and Swift-immature as of 2026-06.
- **macOS 14.4 floor** for taps — confirm the client base; SCK fallback only if
  13.x support is required.
- Confirm the exact tap permission Info.plist key (`NSAudioCaptureUsageDescription`
  vs `NSSystemAudioCaptureUsageDescription`) against the shipping SDK before the
  app build.
