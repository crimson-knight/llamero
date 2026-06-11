require "json"
require "./audio_bridge"
require "./audio_events"
require "./errors"

module Llamero::Native
  # One end-of-utterance-delimited segment from a streaming transcription.
  # Timestamps are milliseconds from the start of the stream, derived from
  # pushed-sample counts (accurate to push granularity).
  struct Utterance
    getter text : String
    getter start_ms : Float64?
    getter end_ms : Float64?

    def initialize(@text : String, @start_ms : Float64? = nil, @end_ms : Float64? = nil)
    end
  end

  # A live speech-to-text stream: the app pushes 16kHz mono Float32 PCM
  # samples (from its own capture layer) and llamero streams text back -
  # partial hypotheses while a phrase is being spoken, and one completed
  # `Utterance` per detected end of utterance (Parakeet EOU, confirmed after
  # a sustained-silence debounce). This is the engine for live dictation.
  #
  # Created via `AudioRuntime#start_stream`; the streaming models load lazily
  # on the first push (`AsrModelLoad*` events fire on the runtime listeners).
  #
  # ```crystal
  # audio = Llamero::Native::AudioRuntime.new
  # stream = audio.start_stream
  # stream.on_partial { |text| print "\r#{text}" }            # live line
  # stream.on_utterance { |utterance| handle(utterance.text) } # completed phrases
  #
  # while samples = capture.next_chunk          # Slice(Float32), 16kHz mono
  #   stream.push(samples)
  # end
  #
  # result = stream.finish # flushes + returns the full session transcript
  # result.text
  # ```
  #
  # Callbacks fire synchronously on the fiber that called `push`/`finish`.
  # Partial text covers the *current* utterance only and restarts after each
  # utterance boundary. `finish` flushes pending audio, emits a final
  # utterance if speech was still in flight, returns the full session text,
  # and leaves the stream unusable (it also releases the bridge handle, so a
  # separate `close` is only needed for streams abandoned before finishing).
  class AudioStream
    # Supported streaming encoder chunk sizes (ms). Smaller = lower latency,
    # larger = higher throughput.
    CHUNK_SIZES_MS = {160, 320, 1280}

    # Streaming encoder chunk size in ms.
    getter chunk_ms : Int32
    # Minimum sustained silence (ms) before an end of utterance is confirmed.
    getter eou_debounce_ms : Int32

    # :nodoc: Use `AudioRuntime#start_stream`.
    def initialize(
      @runtime : AudioRuntime,
      @bridge : AudioBridge,
      @handle : Int64,
      @chunk_ms : Int32,
      @eou_debounce_ms : Int32
    )
      @partial_listeners = [] of String ->
      @utterance_listeners = [] of Utterance ->
      @finished = false
      @closed = false
    end

    # True once `finish` (or `close`) was called; the stream rejects pushes.
    def finished? : Bool
      @finished
    end

    def closed? : Bool
      @closed
    end

    # Registers a listener for partial hypotheses of the current utterance
    # (live "ghost text"; fires whenever new tokens decode during a push).
    def on_partial(&block : String ->) : Nil
      @partial_listeners << block
    end

    # Registers a listener for completed, EOU-detected utterances.
    def on_utterance(&block : Utterance ->) : Nil
      @utterance_listeners << block
    end

    # Pushes captured PCM samples: 16kHz mono Float32. Partial/utterance
    # listeners fire synchronously on the calling fiber before this returns.
    def push(samples : Slice(Float32)) : Nil
      ensure_active
      return if samples.empty?

      error : AudioErrorEvent? = nil
      @bridge.stream_push(@handle, samples.to_unsafe, samples.size.to_i32) do |frame|
        case event = dispatch(frame)
        when AudioErrorEvent then error = event
        end
      end

      if failure = error
        raise failure.to_error
      end
    end

    # Flushes remaining audio, emits a final utterance if speech was still
    # pending, and returns the full session transcript. `segments` carries
    # one entry per utterance. The stream is unusable (and freed) afterwards.
    def finish : TranscriptionResult
      ensure_active
      @finished = true

      error : AudioErrorEvent? = nil
      final : TranscriptFinalEvent? = nil

      begin
        @bridge.stream_finish(@handle) do |frame|
          case event = dispatch(frame)
          when TranscriptFinalEvent then final = event
          when AudioErrorEvent      then error = event
          end
        end
      ensure
        close
      end

      if failure = error
        raise failure.to_error
      end

      final_event = final
      result = final_event || raise TranscriptionError.new("Stream finished without a transcript_final event")
      TranscriptionResult.new(
        text: result.text,
        segments: result.segments,
        duration_ms: result.duration_ms,
        processing_time_ms: result.processing_time_ms,
        confidence: result.confidence,
        language: result.language
      )
    end

    # Releases the bridge-side stream without flushing. Idempotent; called
    # automatically by `finish` and by `AudioRuntime#close`.
    def close : Nil
      return if @closed
      @closed = true
      @finished = true
      @bridge.stream_free(@handle)
    end

    # Fans the frame out to the runtime's typed-event listeners, then to the
    # stream's own partial/utterance callbacks.
    private def dispatch(frame : JSON::Any) : AudioEvent
      event = @runtime.dispatch_frame(frame)
      case event
      when TranscriptPartialEvent
        text = event.text
        @partial_listeners.each(&.call(text))
      when UtteranceEndEvent
        utterance = Utterance.new(text: event.text, start_ms: event.start_ms, end_ms: event.end_ms)
        @utterance_listeners.each(&.call(utterance))
      end
      event
    end

    private def ensure_active : Nil
      raise SessionStateError.new("Audio stream is closed") if @closed
      raise SessionStateError.new("Audio stream is already finished") if @finished
    end
  end
end
