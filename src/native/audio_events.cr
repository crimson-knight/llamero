require "json"
require "./errors"

module Llamero::Native
  # One word-level span of a transcript with millisecond timestamps.
  struct TranscriptSegment
    getter text : String
    getter start_ms : Float64
    getter end_ms : Float64

    def initialize(@text : String, @start_ms : Float64, @end_ms : Float64)
    end

    def self.from_json_any(raw : JSON::Any) : TranscriptSegment
      new(
        text: raw["text"]?.try(&.as_s) || "",
        start_ms: raw["start_ms"]?.try(&.as_f) || 0.0,
        end_ms: raw["end_ms"]?.try(&.as_f) || 0.0
      )
    end
  end

  # One speaker-attributed transcript span.
  struct DiarizedTranscriptSegment
    getter speaker : String
    getter text : String
    getter start_ms : Float64
    getter end_ms : Float64

    def initialize(@speaker : String, @text : String, @start_ms : Float64, @end_ms : Float64)
    end

    def self.from_json_any(raw : JSON::Any) : DiarizedTranscriptSegment
      new(
        speaker: raw["speaker"]?.try(&.as_s) || "S1",
        text: raw["text"]?.try(&.as_s) || "",
        start_ms: raw["start_ms"]?.try(&.as_f) || 0.0,
        end_ms: raw["end_ms"]?.try(&.as_f) || 0.0
      )
    end
  end

  # One diarizer-only speaker activity span, before ASR word alignment.
  struct SpeakerSegment
    getter speaker : String
    getter start_ms : Float64
    getter end_ms : Float64

    def initialize(@speaker : String, @start_ms : Float64, @end_ms : Float64)
    end

    def self.from_json_any(raw : JSON::Any) : SpeakerSegment
      new(
        speaker: raw["speaker"]?.try(&.as_s) || "S1",
        start_ms: raw["start_ms"]?.try(&.as_f) || 0.0,
        end_ms: raw["end_ms"]?.try(&.as_f) || 0.0
      )
    end
  end

  # Typed events produced by an audio bridge (speech-to-text and
  # text-to-speech). The bridge boundary speaks JSON (one object per event);
  # this layer parses those frames into Crystal types, mirroring the
  # NativeEvent hierarchy in events.cr for the MLX bridge.
  #
  # Every event carries the runtime session id and creation time.
  abstract struct AudioEvent
    getter session_id : String
    getter created_at : Time
    getter raw : JSON::Any

    def initialize(@raw : JSON::Any)
      @session_id = @raw["session_id"]?.try(&.as_s) || ""
      @created_at = @raw["created_at"]?.try { |value| Time.parse_rfc3339(value.as_s) } || Time.utc
    end

    # Parses one bridge JSON event frame into a typed event. Unrecognized
    # frames surface as UnknownAudioEvent so callers can log and keep going.
    def self.from_bridge_json(raw : JSON::Any) : AudioEvent
      case raw["event"]?.try(&.as_s)
      when "asr_model_load_started"  then AsrModelLoadStartedEvent.new(raw)
      when "asr_model_load_progress" then AsrModelLoadProgressEvent.new(raw)
      when "asr_model_loaded"        then AsrModelLoadedEvent.new(raw)
      when "diarizer_model_load_started"  then DiarizerModelLoadStartedEvent.new(raw)
      when "diarizer_model_load_progress" then DiarizerModelLoadProgressEvent.new(raw)
      when "diarizer_model_loaded"        then DiarizerModelLoadedEvent.new(raw)
      when "diarization_progress"         then DiarizationProgressEvent.new(raw)
      when "tts_model_load_started"  then TtsModelLoadStartedEvent.new(raw)
      when "tts_model_loaded"        then TtsModelLoadedEvent.new(raw)
      when "transcript_partial"      then TranscriptPartialEvent.new(raw)
      when "utterance_end"           then UtteranceEndEvent.new(raw)
      when "transcript_final"        then TranscriptFinalEvent.new(raw)
      when "diarized_transcript_final" then DiarizedTranscriptFinalEvent.new(raw)
      when "speak_completed"         then SpeakCompletedEvent.new(raw)
      when "error"                   then AudioErrorEvent.new(raw)
      else                                UnknownAudioEvent.new(raw)
      end
    end

    def self.from_bridge_json(json : String) : AudioEvent
      from_bridge_json(JSON.parse(json))
    end
  end

  # Parakeet ASR models started loading (first transcription on a runtime;
  # the first ever load also downloads the CoreML models).
  struct AsrModelLoadStartedEvent < AudioEvent
    getter model_version : String

    def initialize(raw : JSON::Any)
      super(raw)
      @model_version = raw["model_version"]?.try(&.as_s) || "v3"
    end
  end

  # Download/compile progress while the ASR models load (0.0 to 1.0).
  struct AsrModelLoadProgressEvent < AudioEvent
    getter progress : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @progress = raw["progress"]?.try(&.as_f) || 0.0
    end
  end

  # Parakeet ASR models are resident and ready to transcribe.
  struct AsrModelLoadedEvent < AudioEvent
    getter model_version : String
    getter load_time_ms : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @model_version = raw["model_version"]?.try(&.as_s) || "v3"
      @load_time_ms = raw["load_time_ms"]?.try(&.as_f) || 0.0
    end
  end

  # Offline diarizer models started loading (first diarized transcription on
  # a runtime; the first ever load also downloads CoreML bundles).
  struct DiarizerModelLoadStartedEvent < AudioEvent
    getter model_version : String

    def initialize(raw : JSON::Any)
      super(raw)
      @model_version = raw["model_version"]?.try(&.as_s) || "offline-vbx"
    end
  end

  # Download/compile progress while the offline diarizer models load.
  struct DiarizerModelLoadProgressEvent < AudioEvent
    getter progress : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @progress = raw["progress"]?.try(&.as_f) || 0.0
    end
  end

  # Offline diarizer models are resident and ready to process files.
  struct DiarizerModelLoadedEvent < AudioEvent
    getter model_version : String
    getter load_time_ms : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @model_version = raw["model_version"]?.try(&.as_s) || "offline-vbx"
      @load_time_ms = raw["load_time_ms"]?.try(&.as_f) || 0.0
    end
  end

  # Progress from FluidAudio's offline diarizer while it walks segmentation
  # chunks. This can fire during long meeting files.
  struct DiarizationProgressEvent < AudioEvent
    getter progress : Float64
    getter chunks_processed : Int32
    getter total_chunks : Int32

    def initialize(raw : JSON::Any)
      super(raw)
      @progress = raw["progress"]?.try(&.as_f) || 0.0
      @chunks_processed = raw["chunks_processed"]?.try(&.as_i) || 0
      @total_chunks = raw["total_chunks"]?.try(&.as_i) || 0
    end
  end

  # Kokoro TTS chain started loading (first speak on a runtime).
  struct TtsModelLoadStartedEvent < AudioEvent
  end

  # Kokoro TTS chain is resident and ready to synthesize.
  struct TtsModelLoadedEvent < AudioEvent
    getter load_time_ms : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @load_time_ms = raw["load_time_ms"]?.try(&.as_f) || 0.0
    end
  end

  # Partial hypothesis from a streaming transcription: the in-progress text
  # of the *current* utterance (it restarts after each utterance_end). Ideal
  # for a live-updating dictation line.
  struct TranscriptPartialEvent < AudioEvent
    getter text : String

    def initialize(raw : JSON::Any)
      super(raw)
      @text = raw["text"]?.try(&.as_s) || ""
    end
  end

  # One end-of-utterance-detected segment from a streaming transcription
  # (Parakeet EOU confirms after a sustained-silence debounce). Timestamps
  # are derived from pushed-sample counts, so they are accurate to push
  # granularity rather than token-exact.
  struct UtteranceEndEvent < AudioEvent
    getter text : String
    getter start_ms : Float64?
    getter end_ms : Float64?

    def initialize(raw : JSON::Any)
      super(raw)
      @text = raw["text"]?.try(&.as_s) || ""
      @start_ms = raw["start_ms"]?.try(&.as_f)
      @end_ms = raw["end_ms"]?.try(&.as_f)
    end
  end

  # Final transcript for a one-shot file transcription, with word-level
  # timestamped segments. Streaming sessions also emit this on finish, with
  # the full session text and per-utterance segments.
  struct TranscriptFinalEvent < AudioEvent
    getter text : String
    getter segments : Array(TranscriptSegment)
    # Duration of the source audio.
    getter duration_ms : Float64
    # Wall-clock transcription time.
    getter processing_time_ms : Float64
    getter confidence : Float64
    getter language : String?

    def initialize(raw : JSON::Any)
      super(raw)
      @text = raw["text"]?.try(&.as_s) || ""
      @segments = raw["segments"]?.try(&.as_a.map { |segment| TranscriptSegment.from_json_any(segment) }) || [] of TranscriptSegment
      @duration_ms = raw["duration_ms"]?.try(&.as_f) || 0.0
      @processing_time_ms = raw["processing_time_ms"]?.try(&.as_f) || 0.0
      @confidence = raw["confidence"]?.try(&.as_f) || 0.0
      @language = raw["language"]?.try(&.as_s)
    end
  end

  # Final transcript with speaker-attributed segments. The bridge also
  # includes `word_segments` (raw ASR word timestamps) and `speaker_segments`
  # (raw diarizer activity windows) so callers can inspect or realign.
  struct DiarizedTranscriptFinalEvent < AudioEvent
    getter text : String
    getter segments : Array(DiarizedTranscriptSegment)
    getter word_segments : Array(TranscriptSegment)
    getter speaker_segments : Array(SpeakerSegment)
    getter duration_ms : Float64
    getter processing_time_ms : Float64
    getter asr_processing_time_ms : Float64
    getter diarization_processing_time_ms : Float64
    getter confidence : Float64
    getter language : String?

    def initialize(raw : JSON::Any)
      super(raw)
      @text = raw["text"]?.try(&.as_s) || ""
      @segments = raw["segments"]?.try(&.as_a.map { |segment| DiarizedTranscriptSegment.from_json_any(segment) }) || [] of DiarizedTranscriptSegment
      @word_segments = raw["word_segments"]?.try(&.as_a.map { |segment| TranscriptSegment.from_json_any(segment) }) || [] of TranscriptSegment
      @speaker_segments = raw["speaker_segments"]?.try(&.as_a.map { |segment| SpeakerSegment.from_json_any(segment) }) || [] of SpeakerSegment
      @duration_ms = raw["duration_ms"]?.try(&.as_f) || 0.0
      @processing_time_ms = raw["processing_time_ms"]?.try(&.as_f) || 0.0
      @asr_processing_time_ms = raw["asr_processing_time_ms"]?.try(&.as_f) || 0.0
      @diarization_processing_time_ms = raw["diarization_processing_time_ms"]?.try(&.as_f) || 0.0
      @confidence = raw["confidence"]?.try(&.as_f) || 0.0
      @language = raw["language"]?.try(&.as_s)
    end
  end

  # Text-to-speech finished and the WAV file was written.
  struct SpeakCompletedEvent < AudioEvent
    getter path : String
    # Duration of the synthesized audio.
    getter duration_ms : Float64
    # Wall-clock synthesis time.
    getter synthesis_time_ms : Float64
    getter sample_rate : Int32

    def initialize(raw : JSON::Any)
      super(raw)
      @path = raw["path"]?.try(&.as_s) || ""
      @duration_ms = raw["duration_ms"]?.try(&.as_f) || 0.0
      @synthesis_time_ms = raw["synthesis_time_ms"]?.try(&.as_f) || 0.0
      @sample_rate = raw["sample_rate"]?.try(&.as_i) || 0
    end
  end

  # An error reported by the audio bridge as part of the event stream. The
  # runtime layer converts these into typed AudioError exceptions.
  struct AudioErrorEvent < AudioEvent
    getter message : String
    getter code : String
    getter recoverable : Bool

    def initialize(raw : JSON::Any)
      super(raw)
      @message = raw["message"]?.try(&.as_s) || "Unknown audio error"
      @code = raw["code"]?.try(&.as_s) || "audio_error"
      @recoverable = raw["recoverable"]?.try(&.as_bool) || false
    end

    def to_error : AudioError
      case @code
      when "transcription_failed", "stream_failed" then TranscriptionError.new(@message)
      when "diarization_failed"                    then DiarizationError.new(@message)
      when "speak_failed"                          then SpeechSynthesisError.new(@message)
      else
        AudioError.new(@message, @code, @recoverable)
      end
    end
  end

  # Frame the parser did not recognize. Surfaced so callers can log/trace
  # without crashing when the bridge ships a new frame type.
  struct UnknownAudioEvent < AudioEvent
  end
end
