# Building a back-and-forth audio exchange with llamero

This is the integration guide for llamero's audio track: how to build a
**voice conversation** (listen → think → speak, with barge-in) or a
**meeting-notes** experience (dual-channel, speaker-attributed, durable) on
macOS / Apple Silicon. Every API below is verified on-device (see
`audio_conversation_roadmap.md` §9).

## Mental model

llamero gives you the **ears** and the **voice** as composable primitives, and
two orchestrators that wire them into complete experiences. **It does not own
the microphone or the speaker** — audio capture and playback are
OS/AVFoundation concerns your app keeps. So every integration is:

```
[your mic capture] → llamero STT ─┐
                                  ├─→ your reply logic (LLM) → llamero TTS → [your playback]
[your VAD/barge-in]───────────────┘
```

llamero hands you **16 kHz mono Float32** samples in and PCM chunks out; your
app does device I/O. (Why: capture is platform-specific and macOS-version
gated — see "Capture" below.)

## The primitives

| You want | Use | Returns / emits |
|---|---|---|
| Transcribe a finished file | `audio.transcribe(path)` | `TranscriptionResult` (text + word timestamps) |
| Who-said-what on a recording | `audio.transcribe_diarized(path)` | speaker-attributed segments |
| Live dictation | `audio.start_stream` → `push` | `on_partial`, `on_utterance` |
| Crash-safe live transcript | `start_stream(journal: path)` | + JSONL journal, recover with `TranscriptJournal.read` |
| Speak text to a file | `audio.speak(text)` | `SpokenAudio` (a WAV) |
| Speak with low latency | `audio.speak_streaming(text){ }` | one `SpeechChunkEvent` per sentence |
| Stop speaking (barge-in) | `audio.cancel_speech` | — |
| Detect the user talking | `audio.start_vad` → `push` | `on_speech_started`, `on_speech_ended` |
| Meeting notes (mic + system) | `audio.start_meeting` | merged, attributed `Line`s |
| Full conversation loop | `audio.start_conversation{ }` | orchestrates all of the above |

All real processing is gated behind `audio.real_bridge?`; without the built
Swift bridge a deterministic mock keeps your app and specs running anywhere.

## 1. A voice conversation (the smooth back-and-forth)

`ConversationSession` wires streaming STT → your responder → streaming TTS and
tracks the transcript. You provide two things only the app can: **capture**
(feed mic samples) and **playback** (play each reply chunk). The `responder` is
any function from the user's text to a reply — wire it to a local model, a
cloud `Llamero::Client`, or your own logic.

```crystal
require "llamero"

audio = Llamero::Native::AudioRuntime.new

convo = audio.start_conversation { |user_text| my_llm.reply_to(user_text) }
convo.on_user_turn      { |text| puts "user: #{text}" }
convo.on_assistant_turn { |text| puts "assistant: #{text}" }
convo.on_speech_chunk   { |chunk| speaker.enqueue(chunk.pcm, chunk.sample_rate) } # YOUR playback

# YOUR capture loop feeds the mic (16 kHz mono Float32):
while samples = mic.next_chunk
  convo.push_audio(samples)
end
transcript = convo.finish
```

A turn (responder + spoken reply) runs synchronously inside `push_audio` on the
fiber that detected the end of the user's utterance — perfect for a half-duplex
"speak, then listen" exchange. The reply is emitted sentence-by-sentence
(`on_speech_chunk`) so you can start playing sentence one while the rest
synthesizes — low time-to-first-audio.

### Barge-in (let the user interrupt)

Run a `VadStream` on the mic on a **separate thread** and call `barge_in` the
instant it reports speech; that cancels the in-flight spoken reply:

```crystal
vad = audio.start_vad
vad.on_speech_started { convo.barge_in }   # cancels the assistant mid-sentence
# feed the same mic samples to `vad.push` from your capture thread
```

Barge-in is verified on-device: cancelling stops synthesis before the next
sentence and `speak_streaming` returns `nil`.

## 2. Meeting notes (dual-channel, speaker-attributed)

The channel IS the speaker: the **mic** is you, the **system audio** is everyone
else. `MeetingSession` owns two labeled streams and merges them into one
time-ordered, attributed transcript.

```crystal
meeting = audio.start_meeting(journal: Path["~/.llamero/meetings/today.jsonl"])
meeting.on_line { |line| puts "#{line.speaker}: #{line.text}" } # "Me" / "Them"

# YOUR capture, two sources:
meeting.push_me(mic_samples)       # local microphone  → "Me"
meeting.push_them(system_samples)  # system/remote audio → "Them"

transcript = meeting.finish
```

For multiple remote people on one call, run offline `transcribe_diarized` over a
saved recording of the system channel to split "Them" into individual speakers.

## 3. Capture & playback (the app's job, on macOS)

llamero never touches audio devices. Build these once in your app:

- **Microphone:** `AVAudioEngine` tap on `inputNode` → resample to 16 kHz mono
  Float32 → `push`. Needs `NSMicrophoneUsageDescription`.
- **System audio (for meetings):** **Core Audio process taps**
  (`AudioHardwareCreateProcessTap`, macOS 14.4+) — no driver to install, a
  one-time permission, and you can tap just the meeting app's process and
  exclude your own. Do NOT ship a loopback driver (BlackHole is GPL-3.0; a
  DriverKit dext needs an Apple entitlement and is barred from the App Store).
  ScreenCaptureKit audio is a macOS-13 fallback but re-prompts periodically on
  Sequoia. Resample its 48 kHz output to 16 kHz mono before `push`.
- **Playback:** schedule each `SpeechChunkEvent#pcm` (16-bit LE at
  `sample_rate`, 24 kHz from Kokoro) onto a single persistent `AVAudioPlayerNode`
  so playback is gapless across sentences.

Detail and rationale: `audio_conversation_roadmap.md` §3.

## 4. Durability

Pass `journal:` to `start_stream`, `start_meeting`, or `start_conversation` and
every confirmed utterance is appended + fsync'd to a JSONL file the instant it
is detected. A crash loses at most the in-flight phrase. Recover with:

```crystal
Llamero::Native::TranscriptJournal.read(path)         # => Array(Entry)
Llamero::Native::TranscriptJournal.recover_text(path) # => String
```

## Caveats (read before shipping)

- **Turn endpointing on low-energy audio.** `ConversationSession`/`start_stream`
  use the Parakeet EOU model for utterance boundaries. It transcribes continuous
  speech accurately, but does NOT reliably fire on long *pure-silence* gaps
  (verified). Real mic audio carries room tone, so this may not bite — but for
  robust endpointing prefer **VAD-gated turns**: use `start_vad`'s
  `on_speech_ended` to mark the end of a turn. (Tracked as the fix for the EOU
  known-issue.)
- **Streaming TTS is per-sentence**, not sub-sentence. Time-to-first-audio = the
  first sentence's synthesis time. Kokoro runs on the **ANE**, leaving the GPU
  for a local LLM.
- **macOS only** for system-audio capture (iOS sandboxes other apps' audio).
- **Threading.** A conversation turn blocks `push_audio` while it thinks and
  speaks. Full-duplex barge-in needs a separate capture/VAD thread (above).

## Runnable examples

- `examples/native_conversation_test.cr` — the full loop with a canned responder
- `examples/native_streaming_tts_test.cr` — streaming TTS + TTFA
- `examples/native_bargein_test.cr` — cancel mid-reply
- `examples/native_vad_test.cr` — speech start/end detection
- `examples/native_meeting_test.cr` — dual-channel attribution
- `examples/native_dictation_test.cr` — live streaming STT
- `examples/native_audio_test.cr` — file transcribe + speak

Build the bridge first: `cd native/llamero-audio && ./build.sh`.
```
