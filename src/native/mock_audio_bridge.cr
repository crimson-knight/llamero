require "json"
require "./audio_bridge"

module Llamero::Native
  # Deterministic in-process audio bridge used for specs and non-Apple
  # development, mirroring MockBridge for the LLM track.
  #
  # Behavior is fully predictable: transcripts derive from the input
  # filename (or a scripted queue), segment timestamps are synthetic, and
  # speak writes a small valid WAV file. Model "loading" happens lazily on
  # first use per runtime, like the real bridge.
  #
  # ```crystal
  # bridge = Llamero::Native::MockAudioBridge.new
  # bridge.scripted_transcripts << "hello from the mock"
  # audio = Llamero::Native::AudioRuntime.new(bridge: bridge)
  # ```
  class MockAudioBridge < AudioBridge
    # Deterministic metrics every mock operation reports.
    ASR_LOAD_TIME_MS  = 80.0
    TTS_LOAD_TIME_MS  = 60.0
    PROCESSING_TIME_MS = 25.0
    SYNTHESIS_TIME_MS  = 30.0
    SAMPLE_RATE        = 16_000
    # Synthetic per-word segment timing.
    WORD_SPACING_MS = 500.0
    WORD_LENGTH_MS  = 400.0

    private class RuntimeState
      property config : JSON::Any
      property asr_loaded = false
      property tts_loaded = false

      def initialize(@config : JSON::Any)
      end
    end

    # Queue of canned transcripts; each transcription shifts one off. When
    # empty, "mock transcript of <basename>" is produced instead.
    getter scripted_transcripts = [] of String

    # Failure knobs: set to true to make the next matching call emit an
    # error event (the knob resets automatically; the runtime stays usable).
    property fail_next_transcription = false
    property fail_next_speak = false

    def initialize
      @next_handle = 1_i64
      @runtimes = {} of Int64 => RuntimeState
    end

    def name : String
      "mock"
    end

    def real? : Bool
      false
    end

    def create_runtime(config_json : String) : Int64
      handle = next_handle
      @runtimes[handle] = RuntimeState.new(JSON.parse(config_json))
      handle
    end

    def free_runtime(runtime : Int64) : Nil
      @runtimes.delete(runtime)
    end

    def transcribe_file(runtime : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      state = runtime_state(runtime)
      request = JSON.parse(request_json)
      path = request["path"]?.try(&.as_s) || ""

      if @fail_next_transcription
        @fail_next_transcription = false
        emit(on_event, runtime, {
          "event" => "error", "message" => "Mock transcription failure",
          "code" => "transcription_failed", "recoverable" => true,
        })
        return
      end

      unless state.asr_loaded
        version = state.config["asr_model_version"]?.try(&.as_s) || "v3"
        emit(on_event, runtime, {"event" => "asr_model_load_started", "model_version" => version})
        emit(on_event, runtime, {"event" => "asr_model_load_progress", "progress" => 1.0})
        emit(on_event, runtime, {
          "event" => "asr_model_loaded", "model_version" => version,
          "load_time_ms" => ASR_LOAD_TIME_MS,
        })
        state.asr_loaded = true
      end

      text = @scripted_transcripts.shift? || "mock transcript of #{File.basename(path)}"
      segments = text.split.map_with_index do |word, index|
        start_ms = index * WORD_SPACING_MS
        {"text" => word, "start_ms" => start_ms, "end_ms" => start_ms + WORD_LENGTH_MS}
      end
      duration_ms = segments.last?.try(&.["end_ms"].as(Float64)) || 0.0

      emit(on_event, runtime, {
        "event" => "transcript_final", "text" => text, "segments" => segments,
        "duration_ms" => duration_ms, "processing_time_ms" => PROCESSING_TIME_MS,
        "confidence" => 1.0,
      })
    end

    def speak(runtime : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      state = runtime_state(runtime)
      request = JSON.parse(request_json)

      if @fail_next_speak
        @fail_next_speak = false
        emit(on_event, runtime, {
          "event" => "error", "message" => "Mock speech synthesis failure",
          "code" => "speak_failed", "recoverable" => true,
        })
        return
      end

      text = request["text"]?.try(&.as_s) || ""
      if text.empty?
        emit(on_event, runtime, {
          "event" => "error", "message" => "Cannot speak empty text",
          "code" => "speak_failed", "recoverable" => true,
        })
        return
      end

      unless state.tts_loaded
        emit(on_event, runtime, {"event" => "tts_model_load_started"})
        emit(on_event, runtime, {"event" => "tts_model_loaded", "load_time_ms" => TTS_LOAD_TIME_MS})
        state.tts_loaded = true
      end

      output_path = request["output_path"]?.try(&.as_s) ||
                    File.join(Dir.tempdir, "llamero-mock-speak-#{runtime}-#{Time.utc.to_unix_ms}.wav")

      # Deterministic duration: 100ms of silence per word.
      sample_count = text.split.size * SAMPLE_RATE // 10
      sample_count = SAMPLE_RATE // 10 if sample_count.zero?
      write_silent_wav(output_path, sample_count)

      emit(on_event, runtime, {
        "event" => "speak_completed", "path" => output_path,
        "duration_ms" => sample_count * 1000.0 / SAMPLE_RATE,
        "synthesis_time_ms" => SYNTHESIS_TIME_MS, "sample_rate" => SAMPLE_RATE,
      })
    end

    # Spec helpers: inspect per-runtime state without going through events.

    def asr_loaded?(runtime : Int64) : Bool
      runtime_state(runtime).asr_loaded
    end

    def tts_loaded?(runtime : Int64) : Bool
      runtime_state(runtime).tts_loaded
    end

    private def runtime_state(runtime : Int64) : RuntimeState
      @runtimes[runtime]? || raise BridgeUnavailableError.new("Unknown audio runtime handle: #{runtime}")
    end

    private def next_handle : Int64
      handle = @next_handle
      @next_handle += 1
      handle
    end

    # Writes a minimal valid WAV file: 44-byte RIFF/PCM header followed by
    # 16-bit mono silence.
    private def write_silent_wav(path : String, sample_count : Int32) : Nil
      Dir.mkdir_p(File.dirname(path))
      data_size = sample_count * 2

      File.open(path, "w") do |file|
        file << "RIFF"
        file.write_bytes((36 + data_size).to_u32, IO::ByteFormat::LittleEndian)
        file << "WAVE"
        file << "fmt "
        file.write_bytes(16_u32, IO::ByteFormat::LittleEndian)               # fmt chunk size
        file.write_bytes(1_u16, IO::ByteFormat::LittleEndian)                # PCM
        file.write_bytes(1_u16, IO::ByteFormat::LittleEndian)                # mono
        file.write_bytes(SAMPLE_RATE.to_u32, IO::ByteFormat::LittleEndian)   # sample rate
        file.write_bytes((SAMPLE_RATE * 2).to_u32, IO::ByteFormat::LittleEndian) # byte rate
        file.write_bytes(2_u16, IO::ByteFormat::LittleEndian)                # block align
        file.write_bytes(16_u16, IO::ByteFormat::LittleEndian)               # bits per sample
        file << "data"
        file.write_bytes(data_size.to_u32, IO::ByteFormat::LittleEndian)
        sample_count.times { file.write_bytes(0_i16, IO::ByteFormat::LittleEndian) }
      end
    end

    private def emit(on_event : JSON::Any ->, runtime : Int64, payload) : Nil
      frame = {
        "session_id" => "mock-audio-runtime-#{runtime}",
        "created_at" => Time.utc.to_rfc3339,
      }.merge(payload)
      on_event.call(JSON.parse(frame.to_json))
    end
  end
end
