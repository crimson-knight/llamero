require "json"
require "./audio_bridge"

module Llamero::Native
  # Deterministic in-process audio bridge used for specs and non-Apple
  # development, mirroring MockBridge for the LLM track.
  #
  # Behavior is fully predictable: transcripts derive from the input
  # filename (or a scripted queue), segment timestamps are synthetic, and
  # speak writes a small valid WAV file. Model "loading" happens lazily on
  # first use per runtime, like the real bridge. Streaming STT reveals one
  # word of the next scripted utterance per push (see `scripted_utterances`
  # and StreamState below).
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
      # Streaming (Parakeet EOU) models are separate from the one-shot ASR
      # models and load lazily on a stream's first push.
      property stream_asr_loaded = false

      def initialize(@config : JSON::Any)
      end
    end

    # Deterministic streaming behavior, mirroring the real bridge's shape:
    # each push emits one transcript_partial (the current utterance grows by
    # one scripted word per push), an utterance_end fires when a scripted
    # utterance's words are exhausted, and finish flushes any in-progress
    # utterance before transcript_final with the full session text.
    # Timestamps derive from pushed sample counts at 16kHz.
    private class StreamState
      property runtime : Int64
      property chunk_ms : Int32
      property pushed_samples = 0_i64
      property push_count = 0
      property current_utterance : String?
      property words = [] of String
      property word_index = 0
      property utterance_start_ms = 0.0
      property completed = [] of String
      property segments = [] of NamedTuple(text: String, start_ms: Float64, end_ms: Float64)
      property finished = false

      def initialize(@runtime : Int64, @chunk_ms : Int32)
      end
    end

    # Queue of canned transcripts; each transcription shifts one off. When
    # empty, "mock transcript of <basename>" is produced instead.
    getter scripted_transcripts = [] of String

    # Queue of canned streaming utterances, shared across streams. A stream
    # picks up the next utterance when idle and reveals one word per push as
    # a partial; the utterance_end fires on the push that completes it. When
    # the queue is empty, pushes emit empty partials (silence).
    getter scripted_utterances = [] of String

    # Failure knobs: set to true to make the next matching call emit an
    # error event (the knob resets automatically; the runtime stays usable).
    property fail_next_transcription = false
    property fail_next_speak = false
    property fail_next_stream_push = false
    property fail_next_stream_finish = false

    def initialize
      @next_handle = 1_i64
      @runtimes = {} of Int64 => RuntimeState
      @streams = {} of Int64 => StreamState
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
      # Streams cannot outlive their parent runtime.
      @streams.reject! { |_, state| state.runtime == runtime }
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

    def stream_create(runtime : Int64, config_json : String) : Int64
      runtime_state(runtime) # validates the parent handle
      config = JSON.parse(config_json)
      chunk_ms = config["chunk_ms"]?.try(&.as_i) || 160
      handle = next_handle
      @streams[handle] = StreamState.new(runtime, chunk_ms)
      handle
    end

    def stream_push(stream : Int64, samples : Pointer(Float32), count : Int32, &on_event : JSON::Any ->) : Nil
      state = stream_state(stream)
      if state.finished
        raise NativeError.new("Audio stream #{stream} is already finished", "stream_finished")
      end

      if @fail_next_stream_push
        @fail_next_stream_push = false
        emit_stream(on_event, stream, {
          "event" => "error", "message" => "Mock stream push failure",
          "code" => "stream_failed", "recoverable" => true,
        })
        return
      end

      ensure_stream_models_loaded(state, stream, on_event)

      state.push_count += 1
      state.pushed_samples += count

      if state.current_utterance.nil? && (next_text = @scripted_utterances.shift?)
        state.current_utterance = next_text
        state.words = next_text.split
        state.word_index = 0
        state.utterance_start_ms = ms(state.pushed_samples - count)
      end

      if current = state.current_utterance
        state.word_index += 1
        partial = state.words[0, state.word_index].join(" ")
        emit_stream(on_event, stream, {"event" => "transcript_partial", "text" => partial})
        if state.word_index >= state.words.size
          complete_utterance(state, current, stream, on_event)
        end
      else
        # Nothing scripted: silence decodes to an empty partial.
        emit_stream(on_event, stream, {"event" => "transcript_partial", "text" => ""})
      end
    end

    def stream_finish(stream : Int64, &on_event : JSON::Any ->) : Nil
      state = stream_state(stream)
      if state.finished
        raise NativeError.new("Audio stream #{stream} is already finished", "stream_finished")
      end
      state.finished = true

      if @fail_next_stream_finish
        @fail_next_stream_finish = false
        emit_stream(on_event, stream, {
          "event" => "error", "message" => "Mock stream finish failure",
          "code" => "stream_failed", "recoverable" => true,
        })
        return
      end

      # Flushing the remaining audio decodes the rest of an in-progress
      # utterance, like the real bridge's padded final chunk.
      if current = state.current_utterance
        complete_utterance(state, current, stream, on_event)
      end

      emit_stream(on_event, stream, {
        "event"              => "transcript_final",
        "text"               => state.completed.join(" "),
        "segments"           => state.segments,
        "duration_ms"        => ms(state.pushed_samples),
        "processing_time_ms" => PROCESSING_TIME_MS,
        "confidence"         => 1.0,
      })
    end

    def stream_free(stream : Int64) : Nil
      @streams.delete(stream)
    end

    # Spec helpers: inspect per-runtime state without going through events.

    def asr_loaded?(runtime : Int64) : Bool
      runtime_state(runtime).asr_loaded
    end

    def stream_asr_loaded?(runtime : Int64) : Bool
      runtime_state(runtime).stream_asr_loaded
    end

    def tts_loaded?(runtime : Int64) : Bool
      runtime_state(runtime).tts_loaded
    end

    private def runtime_state(runtime : Int64) : RuntimeState
      @runtimes[runtime]? || raise BridgeUnavailableError.new("Unknown audio runtime handle: #{runtime}")
    end

    private def stream_state(stream : Int64) : StreamState
      @streams[stream]? || raise BridgeUnavailableError.new("Unknown audio stream handle: #{stream}")
    end

    # Streaming models load once per runtime (the real bridge parks the
    # loaded manager on the runtime when a stream closes, so only the first
    # stream pays the load).
    private def ensure_stream_models_loaded(state : StreamState, stream : Int64, on_event : JSON::Any ->) : Nil
      runtime = runtime_state(state.runtime)
      return if runtime.stream_asr_loaded

      label = "eou-#{state.chunk_ms}ms"
      emit_stream(on_event, stream, {"event" => "asr_model_load_started", "model_version" => label})
      emit_stream(on_event, stream, {"event" => "asr_model_load_progress", "progress" => 1.0})
      emit_stream(on_event, stream, {
        "event" => "asr_model_loaded", "model_version" => label,
        "load_time_ms" => ASR_LOAD_TIME_MS,
      })
      runtime.stream_asr_loaded = true
    end

    private def complete_utterance(state : StreamState, text : String, stream : Int64, on_event : JSON::Any ->) : Nil
      end_ms = ms(state.pushed_samples)
      emit_stream(on_event, stream, {
        "event" => "utterance_end", "text" => text,
        "start_ms" => state.utterance_start_ms, "end_ms" => end_ms,
      })
      state.completed << text
      state.segments << {text: text, start_ms: state.utterance_start_ms, end_ms: end_ms}
      state.current_utterance = nil
      state.words = [] of String
      state.word_index = 0
    end

    private def ms(samples : Int64) : Float64
      samples * 1000.0 / SAMPLE_RATE
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
      emit_frame(on_event, "mock-audio-runtime-#{runtime}", payload)
    end

    private def emit_stream(on_event : JSON::Any ->, stream : Int64, payload) : Nil
      emit_frame(on_event, "mock-audio-stream-#{stream}", payload)
    end

    private def emit_frame(on_event : JSON::Any ->, session_id : String, payload) : Nil
      frame = {
        "session_id" => session_id,
        "created_at" => Time.utc.to_rfc3339,
      }.merge(payload)
      on_event.call(JSON.parse(frame.to_json))
    end
  end
end
