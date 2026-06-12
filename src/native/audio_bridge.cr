require "json"
require "../config/storage"
require "./errors"
require "./mlx_bridge" # for the shared LibDL declarations

module Llamero::Native
  # Abstract boundary between the Crystal audio API (AudioRuntime) and a
  # native speech backend.
  #
  # Same contract shape as Bridge (the LLM track): configuration and
  # requests cross as JSON strings; results stream back as JSON event frames
  # (see AudioEvent.from_bridge_json). Handles are opaque integer tokens
  # owned by the bridge.
  #
  # Implementations:
  # - MockAudioBridge: deterministic, in-process, runs anywhere. Used by
  #   specs and non-Apple development.
  # - AudioFFIBridge: dlopen-based FFI binding to the Swift audio bridge
  #   dylib (FluidAudio: Parakeet ASR + Kokoro TTS on the Neural Engine).
  abstract class AudioBridge
    # Picks the best available bridge: the real audio bridge when its dylib
    # can be found and loaded on this machine, otherwise the mock bridge.
    def self.auto : AudioBridge
      AudioFFIBridge.try_load || MockAudioBridge.new
    end

    # Human-readable backend name (e.g. "fluid_audio", "mock").
    abstract def name : String

    # True when this bridge performs real native speech processing.
    abstract def real? : Bool

    # Creates a runtime from a JSON config ({"asr_model_version": "v3",
    # "tts_voice": "af_heart"}; both optional). Returns an opaque handle.
    # Nothing heavy is loaded at create time - models load lazily on first
    # transcribe/speak, emitting *_model_load_started/loaded events.
    abstract def create_runtime(config_json : String) : Int64

    abstract def free_runtime(runtime : Int64) : Nil

    # One-shot file transcription, yielding JSON event frames
    # (asr_model_load_started/progress/loaded on first use, then
    # transcript_final, or error). Request JSON: {"path": "/abs/file.wav"}.
    abstract def transcribe_file(runtime : Int64, request_json : String, &on_event : JSON::Any ->) : Nil

    # One-shot file transcription with speaker diarization. Runs Parakeet ASR
    # for word timestamps and FluidAudio's offline diarizer for speaker
    # segments, then yields diarized_transcript_final with speaker-attributed
    # transcript segments. Config JSON supports optional clustering_threshold,
    # speaker_count, min_speakers, and max_speakers.
    abstract def transcribe_diarized_file(runtime : Int64, path : String, config_json : String, &on_event : JSON::Any ->) : Nil

    # Text-to-speech to a WAV file, yielding event frames
    # (tts_model_load_started/loaded on first use, then speak_completed with
    # the output path, or error). Request JSON: {"text": "...", "voice":
    # optional, "output_path": optional}.
    abstract def speak(runtime : Int64, request_json : String, &on_event : JSON::Any ->) : Nil

    # Creates a streaming speech-to-text session on a runtime and returns an
    # opaque stream handle. Config JSON (all keys optional):
    # {"chunk_ms": 160|320|1280, "eou_debounce_ms": 1280}. Nothing heavy is
    # loaded at create time - the streaming ASR models load lazily on the
    # first push (emitting asr_model_load_* events).
    abstract def stream_create(runtime : Int64, config_json : String) : Int64

    # Pushes PCM samples into a stream. Samples MUST be 16kHz mono Float32
    # (`count` is the number of Float32 samples, not bytes). Yields
    # transcript_partial frames (in-progress utterance text) and
    # utterance_end frames (one per detected end of utterance), plus
    # asr_model_load_* on first use and error frames.
    abstract def stream_push(stream : Int64, samples : Pointer(Float32), count : Int32, &on_event : JSON::Any ->) : Nil

    # Flushes a stream: processes remaining audio, yields a final
    # utterance_end if speech was still pending, then transcript_final with
    # the full session text. The stream is unusable afterwards.
    abstract def stream_finish(stream : Int64, &on_event : JSON::Any ->) : Nil

    # Releases a stream handle (idempotent on the bridge side).
    abstract def stream_free(stream : Int64) : Nil
  end

  # FFI binding to the Swift audio bridge dylib (libLlameroAudioBridge.dylib,
  # built from native/llamero-audio).
  #
  # ## C ABI contract (implemented by native/llamero-audio)
  #
  # ```c
  # typedef void (*llamero_event_callback)(const char *json_event, void *user_data);
  #
  # int64_t llamero_audio_runtime_create(const char *json_config); // > 0 handle, <= 0 failure
  # void    llamero_audio_runtime_free(int64_t runtime);
  # int32_t llamero_audio_transcribe_file(int64_t runtime, const char *json_request, llamero_event_callback cb, void *user_data);
  # int32_t llamero_audio_runtime_transcribe_diarized(int64_t runtime, const char *path, const char *config_json, llamero_event_callback cb, void *user_data);
  # int32_t llamero_audio_speak(int64_t runtime, const char *json_request, llamero_event_callback cb, void *user_data);
  #
  # // Streaming STT. samples are 16kHz mono Float32 PCM; count is in samples.
  # int64_t llamero_audio_stream_create(int64_t runtime, const char *json_config); // > 0 handle, <= 0 failure
  # int32_t llamero_audio_stream_push(int64_t stream, const float *samples, int32_t count, llamero_event_callback cb, void *user_data);
  # int32_t llamero_audio_stream_finish(int64_t stream, llamero_event_callback cb, void *user_data);
  # void    llamero_audio_stream_free(int64_t stream);
  # ```
  #
  # All callbacks are invoked synchronously on the calling thread; the Swift
  # side bridges its async FluidAudio work onto the caller via an internal
  # event queue. Errors are reported both as a nonzero status and as an
  # `error` event frame so messages flow through one path.
  class AudioFFIBridge < AudioBridge
    # Trampoline for event callbacks: unboxes the Crystal block from
    # user_data and hands it the JSON frame. Must stay non-closure so it has
    # a bare function pointer.
    EVENT_TRAMPOLINE = ->(json : LibC::Char*, user_data : Void*) do
      Box(Proc(String, Nil)).unbox(user_data).call(String.new(json))
    end

    getter library_path : String

    @dylib : Void*
    @runtime_create : Proc(LibC::Char*, Int64)
    @runtime_free : Proc(Int64, Nil)
    @transcribe_file : Proc(Int64, LibC::Char*, Void*, Void*, Int32)
    @transcribe_diarized_file : Proc(Int64, LibC::Char*, LibC::Char*, Void*, Void*, Int32)
    @speak : Proc(Int64, LibC::Char*, Void*, Void*, Int32)
    @stream_create : Proc(Int64, LibC::Char*, Int64)
    @stream_push : Proc(Int64, Pointer(Float32), Int32, Void*, Void*, Int32)
    @stream_finish : Proc(Int64, Void*, Void*, Int32)
    @stream_free : Proc(Int64, Nil)

    # Locates the bridge dylib. Search order:
    # 1. LLAMERO_AUDIO_LIB environment variable
    # 2. The in-repo Swift build products (native/llamero-audio/.build/...)
    # 3. The shard's build products when llamero is a dependency
    #    (lib/llamero/native/llamero-audio/.build/...)
    # 4. Configured storage lib directory (build.sh installs here by default)
    # 5. /usr/local/lib/libLlameroAudioBridge.dylib
    def self.discover_library_path : String?
      if from_env = ENV["LLAMERO_AUDIO_LIB"]?
        return from_env if File.exists?(from_env)
      end

      [
        "native/llamero-audio/.build/release/libLlameroAudioBridge.dylib",
        "native/llamero-audio/.build/arm64-apple-macosx/release/libLlameroAudioBridge.dylib",
        "lib/llamero/native/llamero-audio/.build/release/libLlameroAudioBridge.dylib",
        "lib/llamero/native/llamero-audio/.build/arm64-apple-macosx/release/libLlameroAudioBridge.dylib",
        Llamero::Storage.lib_dir.join("libLlameroAudioBridge.dylib").to_s,
        "/usr/local/lib/libLlameroAudioBridge.dylib",
      ].find { |candidate| File.exists?(candidate) }
    end

    # Returns a ready bridge when running on Apple Silicon macOS and the
    # dylib can be found and loaded; nil otherwise.
    def self.try_load : AudioFFIBridge?
      {% if flag?(:darwin) && flag?(:aarch64) %}
        if path = discover_library_path
          begin
            return new(path)
          rescue BridgeUnavailableError
            return nil
          end
        end
      {% end %}
      nil
    end

    def initialize(@library_path : String)
      handle = LibDL.dlopen(@library_path, LibDL::RTLD_NOW)
      if handle.null?
        raise BridgeUnavailableError.new("Failed to dlopen #{@library_path}: #{dl_error}")
      end
      @dylib = handle

      @runtime_create = Proc(LibC::Char*, Int64).new(symbol("llamero_audio_runtime_create"), Pointer(Void).null)
      @runtime_free = Proc(Int64, Nil).new(symbol("llamero_audio_runtime_free"), Pointer(Void).null)
      @transcribe_file = Proc(Int64, LibC::Char*, Void*, Void*, Int32).new(symbol("llamero_audio_transcribe_file"), Pointer(Void).null)
      @transcribe_diarized_file = Proc(Int64, LibC::Char*, LibC::Char*, Void*, Void*, Int32).new(symbol("llamero_audio_runtime_transcribe_diarized"), Pointer(Void).null)
      @speak = Proc(Int64, LibC::Char*, Void*, Void*, Int32).new(symbol("llamero_audio_speak"), Pointer(Void).null)
      @stream_create = Proc(Int64, LibC::Char*, Int64).new(symbol("llamero_audio_stream_create"), Pointer(Void).null)
      @stream_push = Proc(Int64, Pointer(Float32), Int32, Void*, Void*, Int32).new(symbol("llamero_audio_stream_push"), Pointer(Void).null)
      @stream_finish = Proc(Int64, Void*, Void*, Int32).new(symbol("llamero_audio_stream_finish"), Pointer(Void).null)
      @stream_free = Proc(Int64, Nil).new(symbol("llamero_audio_stream_free"), Pointer(Void).null)
    end

    def name : String
      "fluid_audio"
    end

    def real? : Bool
      true
    end

    def create_runtime(config_json : String) : Int64
      handle = @runtime_create.call(config_json.to_unsafe)
      if handle <= 0
        raise BridgeUnavailableError.new("Audio bridge failed to create runtime (status #{handle})")
      end
      handle
    end

    def free_runtime(runtime : Int64) : Nil
      @runtime_free.call(runtime)
    end

    def transcribe_file(runtime : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @transcribe_file.call(runtime, request_json.to_unsafe, callback, user_data)
      end
    end

    def transcribe_diarized_file(runtime : Int64, path : String, config_json : String, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @transcribe_diarized_file.call(runtime, path.to_unsafe, config_json.to_unsafe, callback, user_data)
      end
    end

    def speak(runtime : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @speak.call(runtime, request_json.to_unsafe, callback, user_data)
      end
    end

    def stream_create(runtime : Int64, config_json : String) : Int64
      handle = @stream_create.call(runtime, config_json.to_unsafe)
      if handle <= 0
        raise NativeError.new("Audio bridge failed to create stream (status #{handle})", "stream_create_failed")
      end
      handle
    end

    def stream_push(stream : Int64, samples : Pointer(Float32), count : Int32, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @stream_push.call(stream, samples, count, callback, user_data)
      end
    end

    def stream_finish(stream : Int64, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @stream_finish.call(stream, callback, user_data)
      end
    end

    def stream_free(stream : Int64) : Nil
      @stream_free.call(stream)
    end

    # Wraps a C call that streams event frames. Listener exceptions are
    # stashed and re-raised after the native call returns so Crystal
    # exceptions never unwind through Swift frames.
    private def with_events(on_event : JSON::Any ->, &call : (Void*, Void*) -> Int32) : Nil
      deferred_error : Exception? = nil
      saw_error_frame = false

      receiver = ->(json : String) do
        return if deferred_error
        begin
          frame = JSON.parse(json)
          saw_error_frame = true if frame["event"]?.try(&.as_s) == "error"
          on_event.call(frame)
        rescue ex
          deferred_error = ex
        end
        nil
      end

      boxed = Box.box(receiver)
      status = call.call(EVENT_TRAMPOLINE.pointer.as(Void*), boxed)

      if failure = deferred_error
        raise failure
      end

      # A nonzero status with no error frame means the bridge failed before
      # it could report properly (e.g. unknown handle).
      if status != 0 && !saw_error_frame
        raise NativeError.new("Audio bridge call failed with status #{status}", "bridge_call_failed")
      end
    end

    private def symbol(name : String) : Void*
      pointer = LibDL.dlsym(@dylib, name)
      if pointer.null?
        raise BridgeUnavailableError.new("Missing symbol #{name} in #{@library_path}: #{dl_error}")
      end
      pointer
    end

    private def dl_error : String
      message = LibDL.dlerror
      message.null? ? "unknown dlopen error" : String.new(message)
    end
  end
end
