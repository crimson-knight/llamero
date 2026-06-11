require "json"
require "./audio_bridge"
require "./mock_audio_bridge"
require "./audio_events"

module Llamero::Native
  # Result of a one-shot file transcription.
  struct TranscriptionResult
    # Full transcript text.
    getter text : String
    # Word-level segments with millisecond timestamps.
    getter segments : Array(TranscriptSegment)
    # Duration of the source audio.
    getter duration_ms : Float64
    # Wall-clock transcription time.
    getter processing_time_ms : Float64
    getter confidence : Float64
    getter language : String?

    def initialize(
      @text : String,
      @segments : Array(TranscriptSegment),
      @duration_ms : Float64 = 0.0,
      @processing_time_ms : Float64 = 0.0,
      @confidence : Float64 = 0.0,
      @language : String? = nil
    )
    end
  end

  # A synthesized speech artifact on disk.
  struct SpokenAudio
    # WAV file ready to play.
    getter path : Path
    # Duration of the synthesized audio.
    getter duration_ms : Float64
    # Wall-clock synthesis time.
    getter synthesis_time_ms : Float64
    getter sample_rate : Int32

    def initialize(
      @path : Path,
      @duration_ms : Float64,
      @synthesis_time_ms : Float64 = 0.0,
      @sample_rate : Int32 = 0
    )
    end
  end

  # On-device speech-to-text (NVIDIA Parakeet) and text-to-speech (Kokoro)
  # through the FluidAudio bridge - CoreML on the Neural Engine, leaving the
  # GPU to the resident LLM. Without the built audio bridge dylib, a
  # deterministic mock keeps apps and specs working anywhere; gate
  # real-audio code on `real_bridge?`.
  #
  # Models load lazily: the first transcribe downloads/loads the Parakeet
  # models, the first speak loads the Kokoro chain. Progress streams to
  # `on_event` listeners.
  #
  # ```crystal
  # audio = Llamero::Native::AudioRuntime.new
  #
  # result = audio.transcribe(Path["meeting.wav"])
  # result.text       # full transcript
  # result.segments   # word-level {text, start_ms, end_ms}
  #
  # spoken = audio.speak("I found three problems in that file.", voice: "af_heart")
  # spoken.path       # wav file to play
  # ```
  class AudioRuntime
    # Parakeet model generation: "v3" (default, 25 EU languages + ja) or
    # "v2" (English-only).
    getter asr_model_version : String
    # Default Kokoro voice; per-call `voice:` overrides it.
    getter tts_voice : String?
    getter bridge : AudioBridge

    @runtime_handle : Int64

    def initialize(
      @asr_model_version : String = "v3",
      @tts_voice : String? = nil,
      @bridge : AudioBridge = AudioBridge.auto
    )
      unless {"v2", "v3"}.includes?(@asr_model_version)
        raise ArgumentError.new("asr_model_version must be \"v2\" or \"v3\" (got #{@asr_model_version.inspect})")
      end
      @event_listeners = [] of AudioEvent ->
      @closed = false
      @runtime_handle = @bridge.create_runtime(config_json)
    end

    # True when this runtime performs real native speech processing (vs. the
    # mock).
    def real_bridge? : Bool
      @bridge.real?
    end

    def bridge_name : String
      @bridge.name
    end

    def closed? : Bool
      @closed
    end

    # Registers a listener for every typed event this runtime produces
    # (model load progress, transcripts, speech completions, errors).
    def on_event(&block : AudioEvent ->) : Nil
      @event_listeners << block
    end

    # Transcribes an audio file to text with word-level timestamps. The
    # first call loads the ASR models (downloading them on first ever use),
    # emitting AsrModelLoad* events along the way.
    def transcribe(path : Path | String) : TranscriptionResult
      ensure_open
      file_path = Path[path].expand
      unless File.exists?(file_path)
        raise TranscriptionError.new("Audio file not found: #{file_path}")
      end

      error : AudioErrorEvent? = nil
      transcript : TranscriptFinalEvent? = nil

      request_json = {path: file_path.to_s}.to_json
      @bridge.transcribe_file(@runtime_handle, request_json) do |frame|
        event = dispatch(frame)
        case event
        when TranscriptFinalEvent then transcript = event
        when AudioErrorEvent      then error = event
        end
      end

      if failure = error
        raise failure.to_error
      end

      final_transcript = transcript
      final = final_transcript || raise TranscriptionError.new("Bridge finished without a transcript_final event")
      TranscriptionResult.new(
        text: final.text,
        segments: final.segments,
        duration_ms: final.duration_ms,
        processing_time_ms: final.processing_time_ms,
        confidence: final.confidence,
        language: final.language
      )
    end

    # Synthesizes speech to a WAV file and returns its location. The first
    # call loads the Kokoro TTS chain (downloading it on first ever use).
    # Without `output_path` the bridge writes to a temporary file.
    def speak(text : String, voice : String? = nil, output_path : Path | String | Nil = nil) : SpokenAudio
      ensure_open
      raise SpeechSynthesisError.new("Cannot speak empty text") if text.blank?

      error : AudioErrorEvent? = nil
      completed : SpeakCompletedEvent? = nil

      @bridge.speak(@runtime_handle, speak_request_json(text, voice, output_path)) do |frame|
        event = dispatch(frame)
        case event
        when SpeakCompletedEvent then completed = event
        when AudioErrorEvent     then error = event
        end
      end

      if failure = error
        raise failure.to_error
      end

      final_completed = completed
      final = final_completed || raise SpeechSynthesisError.new("Bridge finished without a speak_completed event")
      SpokenAudio.new(
        path: Path[final.path],
        duration_ms: final.duration_ms,
        synthesis_time_ms: final.synthesis_time_ms,
        sample_rate: final.sample_rate
      )
    end

    # Frees the bridge-side runtime. The runtime cannot be used afterwards.
    def close : Nil
      return if @closed
      @bridge.free_runtime(@runtime_handle)
      @closed = true
    end

    private def dispatch(frame : JSON::Any) : AudioEvent
      event = AudioEvent.from_bridge_json(frame)
      @event_listeners.each(&.call(event))
      event
    end

    private def ensure_open : Nil
      raise SessionStateError.new("Audio runtime is closed") if @closed
    end

    private def config_json : String
      JSON.build do |json|
        json.object do
          json.field "asr_model_version", @asr_model_version
          json.field "tts_voice", @tts_voice if @tts_voice
        end
      end
    end

    private def speak_request_json(text : String, voice : String?, output_path : Path | String | Nil) : String
      JSON.build do |json|
        json.object do
          json.field "text", text
          json.field "voice", voice if voice
          if output_path
            json.field "output_path", Path[output_path].expand.to_s
          end
        end
      end
    end
  end
end
