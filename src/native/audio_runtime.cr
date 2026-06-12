require "json"
require "../config/storage"
require "./audio_bridge"
require "./mock_audio_bridge"
require "./audio_events"
require "./audio_stream"

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
      @language : String? = nil,
    )
    end
  end

  # Result of a one-shot file transcription with speaker attribution.
  struct DiarizedTranscriptionResult
    # Full transcript text.
    getter text : String
    # Speaker-attributed transcript spans.
    getter segments : Array(DiarizedTranscriptSegment)
    # Raw ASR word-level segments used for alignment.
    getter word_segments : Array(TranscriptSegment)
    # Raw diarizer speaker activity windows before word alignment.
    getter speaker_segments : Array(SpeakerSegment)
    # Duration of the source audio.
    getter duration_ms : Float64
    # Total wall-clock time for ASR + diarization.
    getter processing_time_ms : Float64
    # Wall-clock ASR model processing time reported by FluidAudio.
    getter asr_processing_time_ms : Float64
    # Wall-clock diarizer processing time measured by the bridge.
    getter diarization_processing_time_ms : Float64
    getter confidence : Float64
    getter language : String?

    def initialize(
      @text : String,
      @segments : Array(DiarizedTranscriptSegment),
      @word_segments : Array(TranscriptSegment),
      @speaker_segments : Array(SpeakerSegment),
      @duration_ms : Float64 = 0.0,
      @processing_time_ms : Float64 = 0.0,
      @asr_processing_time_ms : Float64 = 0.0,
      @diarization_processing_time_ms : Float64 = 0.0,
      @confidence : Float64 = 0.0,
      @language : String? = nil,
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
      @sample_rate : Int32 = 0,
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
  # ```
  # audio = Llamero::Native::AudioRuntime.new
  #
  # result = audio.transcribe(Path["meeting.wav"])
  # result.text     # full transcript
  # result.segments # word-level {text, start_ms, end_ms}
  #
  # spoken = audio.speak("I found three problems in that file.", voice: "af_heart")
  # spoken.path # wav file to play
  #
  # # Streaming STT (live dictation): the app pushes mic samples,
  # # llamero streams text back. See AudioStream.
  # stream = audio.start_stream
  # stream.on_partial { |text| print "\r#{text}" }
  # stream.on_utterance { |utterance| handle(utterance.text) }
  # stream.push(samples) # Slice(Float32), 16kHz mono
  # stream.finish.text   # full session transcript
  # ```
  class AudioRuntime
    # Parakeet model generation: "v3" (default, 25 EU languages + ja) or
    # "v2" (English-only).
    getter asr_model_version : String
    # Default Kokoro voice; per-call `voice:` overrides it.
    getter tts_voice : String?
    # Optional FluidAudio model cache root. When nil, FluidAudio keeps its
    # own defaults.
    getter models_dir : Path?
    getter bridge : AudioBridge

    @runtime_handle : Int64

    def initialize(
      @asr_model_version : String = "v3",
      @tts_voice : String? = nil,
      models_dir : Path | String | Nil = nil,
      @bridge : AudioBridge = AudioBridge.auto,
    )
      unless {"v2", "v3"}.includes?(@asr_model_version)
        raise ArgumentError.new("asr_model_version must be \"v2\" or \"v3\" (got #{@asr_model_version.inspect})")
      end
      models_dir ||= Llamero::Storage.audio_models_dir if Llamero::Storage.configured?
      @models_dir = models_dir ? Path[models_dir].expand : nil
      @event_listeners = [] of AudioEvent ->
      @streams = [] of AudioStream
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

    # Transcribes an audio file and attributes the transcript to speakers.
    # The bridge runs Parakeet ASR for text + word timestamps and
    # FluidAudio's offline diarizer for speaker windows, then aligns words
    # into `{speaker, start_ms, end_ms, text}` segments.
    #
    # `speaker_count` forces an exact number of speakers. `min_speakers` and
    # `max_speakers` bound automatic clustering. `clustering_threshold`
    # overrides FluidAudio's default VBx/AHC threshold.
    def transcribe_diarized(
      path : Path | String,
      speaker_count : Int32? = nil,
      min_speakers : Int32? = nil,
      max_speakers : Int32? = nil,
      clustering_threshold : Float64? = nil,
    ) : DiarizedTranscriptionResult
      ensure_open
      file_path = Path[path].expand
      unless File.exists?(file_path)
        raise DiarizationError.new("Audio file not found: #{file_path}")
      end

      error : AudioErrorEvent? = nil
      transcript : DiarizedTranscriptFinalEvent? = nil

      @bridge.transcribe_diarized_file(@runtime_handle, file_path.to_s, diarization_config_json(
        speaker_count: speaker_count,
        min_speakers: min_speakers,
        max_speakers: max_speakers,
        clustering_threshold: clustering_threshold
      )) do |frame|
        event = dispatch(frame)
        case event
        when DiarizedTranscriptFinalEvent then transcript = event
        when AudioErrorEvent              then error = event
        end
      end

      if failure = error
        raise failure.to_error
      end

      final_transcript = transcript
      final = final_transcript || raise DiarizationError.new("Bridge finished without a diarized_transcript_final event")
      DiarizedTranscriptionResult.new(
        text: final.text,
        segments: final.segments,
        word_segments: final.word_segments,
        speaker_segments: final.speaker_segments,
        duration_ms: final.duration_ms,
        processing_time_ms: final.processing_time_ms,
        asr_processing_time_ms: final.asr_processing_time_ms,
        diarization_processing_time_ms: final.diarization_processing_time_ms,
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

    # Opens a streaming speech-to-text session (live dictation): push 16kHz
    # mono Float32 samples, get partial hypotheses and EOU-segmented
    # utterances back. The Parakeet EOU streaming models load lazily on the
    # first push (emitting AsrModelLoad* events); when a stream is finished
    # or closed its loaded models are parked on the runtime, so the next
    # stream with the same configuration starts instantly.
    #
    # `chunk_ms` picks the streaming encoder variant (160 = lowest latency,
    # 320, 1280 = highest throughput); `eou_debounce_ms` is the sustained
    # silence required before an utterance boundary is confirmed.
    def start_stream(chunk_ms : Int32 = 160, eou_debounce_ms : Int32 = 1280) : AudioStream
      ensure_open
      unless AudioStream::CHUNK_SIZES_MS.includes?(chunk_ms)
        raise ArgumentError.new("chunk_ms must be one of #{AudioStream::CHUNK_SIZES_MS} (got #{chunk_ms})")
      end
      if eou_debounce_ms < 0
        raise ArgumentError.new("eou_debounce_ms cannot be negative (got #{eou_debounce_ms})")
      end

      config_json = {chunk_ms: chunk_ms, eou_debounce_ms: eou_debounce_ms}.to_json
      handle = @bridge.stream_create(@runtime_handle, config_json)
      stream = AudioStream.new(self, @bridge, handle, chunk_ms, eou_debounce_ms)
      @streams << stream
      stream
    end

    # Frees the bridge-side runtime (closing any open streams first). The
    # runtime cannot be used afterwards.
    def close : Nil
      return if @closed
      @streams.each(&.close)
      @streams.clear
      @bridge.free_runtime(@runtime_handle)
      @closed = true
    end

    # :nodoc: Internal - lets AudioStream fan its frames out to this
    # runtime's typed-event listeners.
    def dispatch_frame(frame : JSON::Any) : AudioEvent
      dispatch(frame)
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
          json.field "models_dir", @models_dir.to_s if @models_dir
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

    private def diarization_config_json(
      speaker_count : Int32?,
      min_speakers : Int32?,
      max_speakers : Int32?,
      clustering_threshold : Float64?,
    ) : String
      JSON.build do |json|
        json.object do
          json.field "speaker_count", speaker_count if speaker_count
          json.field "min_speakers", min_speakers if min_speakers
          json.field "max_speakers", max_speakers if max_speakers
          json.field "clustering_threshold", clustering_threshold if clustering_threshold
        end
      end
    end
  end
end
