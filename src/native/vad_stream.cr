require "json"
require "./audio_bridge"
require "./audio_events"
require "./errors"

module Llamero::Native
  # A live voice-activity-detection stream (Silero VAD): the app pushes 16 kHz
  # mono Float32 samples and llamero reports when speech STARTS and STOPS.
  #
  # The primary use is **barge-in** — run VAD on the mic while the assistant is
  # speaking, and the instant `on_speech_started` fires, cancel playback and
  # `cancel_speech`. It is also useful for silence-gating (don't feed silence
  # to the ASR) and as a more robust endpoint signal than the streaming EOU
  # model on low-energy audio.
  #
  # Created via `AudioRuntime#start_vad`; the Silero model loads lazily on the
  # first push (`VadModelLoad*` events fire on the runtime listeners).
  #
  # ```
  # vad = audio.start_vad
  # vad.on_speech_started { audio.cancel_speech } # barge-in
  # vad.on_speech_ended { |e| puts "user paused at #{e.time_ms}ms" }
  #
  # while samples = capture.next_chunk # Slice(Float32), 16kHz mono
  #   vad.push(samples)
  # end
  # vad.close
  # ```
  class VadStream
    # Silero speech-probability threshold (0..1).
    getter threshold : Float64
    # Sustained silence (ms) before speech_ended is confirmed.
    getter min_silence_ms : Int32

    # :nodoc: Use `AudioRuntime#start_vad`.
    def initialize(
      @runtime : AudioRuntime,
      @bridge : AudioBridge,
      @handle : Int64,
      @threshold : Float64,
      @min_silence_ms : Int32,
    )
      @started_listeners = [] of SpeechStartedEvent ->
      @ended_listeners = [] of SpeechEndedEvent ->
      @closed = false
    end

    def closed? : Bool
      @closed
    end

    # Registers a listener fired when the speaker starts talking (barge-in).
    def on_speech_started(&block : SpeechStartedEvent ->) : Nil
      @started_listeners << block
    end

    # Registers a listener fired when sustained silence confirms speech stopped.
    def on_speech_ended(&block : SpeechEndedEvent ->) : Nil
      @ended_listeners << block
    end

    # Pushes captured PCM samples (16 kHz mono Float32). Speech-start/end
    # listeners fire synchronously on the calling fiber before this returns.
    def push(samples : Slice(Float32)) : Nil
      raise SessionStateError.new("VAD stream is closed") if @closed
      return if samples.empty?

      error : AudioErrorEvent? = nil
      @bridge.vad_push(@handle, samples.to_unsafe, samples.size.to_i32) do |frame|
        case event = dispatch(frame)
        when AudioErrorEvent then error = event
        end
      end

      if failure = error
        raise failure.to_error
      end
    end

    # Releases the bridge-side VAD stream. Idempotent.
    def close : Nil
      return if @closed
      @closed = true
      @bridge.vad_free(@handle)
    end

    private def dispatch(frame : JSON::Any) : AudioEvent
      event = @runtime.dispatch_frame(frame)
      case event
      when SpeechStartedEvent then @started_listeners.each(&.call(event))
      when SpeechEndedEvent   then @ended_listeners.each(&.call(event))
      end
      event
    end
  end
end
