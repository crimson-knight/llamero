require "json"
require "./audio_runtime"

module Llamero::Native
  # Orchestrates a back-and-forth voice conversation: streaming speech-to-text
  # → your reply generator → streaming text-to-speech, with barge-in. It wires
  # the verified building blocks together and tracks the running transcript,
  # leaving the two things only the app can do — audio CAPTURE and PLAYBACK —
  # as explicit hooks.
  #
  # It is intentionally LLM-agnostic: you pass a `responder` that turns the
  # user's text into a reply, so it works with a local `ModelSession`, a cloud
  # `Llamero::Client`, or anything else.
  #
  # ```
  # convo = audio.start_conversation { |user_text| my_llm.reply_to(user_text) }
  # convo.on_user_turn { |text| puts "user: #{text}" }
  # convo.on_assistant_turn { |text| puts "assistant: #{text}" }
  # convo.on_speech_chunk { |chunk| speaker.enqueue(chunk.pcm, chunk.sample_rate) } # app plays
  #
  # # app capture loop feeds the mic:
  # convo.push_audio(mic_samples) # Slice(Float32), 16kHz mono
  # ```
  #
  # ## Threading & barge-in
  #
  # A turn (responder + spoken reply) runs synchronously inside `push_audio`
  # (on the fiber that detected the end of the user's utterance). That is
  # exactly right for a half-duplex "speak, then listen" exchange. For
  # full-duplex **barge-in** — letting the user cut in while the assistant is
  # talking — run a `VadStream` on the mic on a SEPARATE thread and call
  # `barge_in` the instant it reports speech; that cancels the in-flight spoken
  # reply. (Capture and playback are OS/AVFoundation concerns the app owns; see
  # `development_docs/audio_integration_guide.md`.)
  class ConversationSession
    # One turn of the conversation.
    struct Turn
      getter role : String # "user" or "assistant"
      getter text : String

      def initialize(@role : String, @text : String)
      end
    end

    getter voice : String?

    # :nodoc: Use `AudioRuntime#start_conversation`.
    def initialize(
      @audio : AudioRuntime,
      @voice : String? = nil,
      journal : Path | String | Nil = nil,
      &@responder : String -> String
    )
      @stream = @audio.start_stream(source: "user", journal: journal)
      @transcript = [] of Turn
      @user_listeners = [] of String ->
      @assistant_listeners = [] of String ->
      @chunk_listeners = [] of SpeechChunkEvent ->
      @pending = [] of String
      @speaking = false
      # Only QUEUE the utterance here — responding (which makes its own blocking
      # bridge call to speak) must happen AFTER the stream's push/finish call
      # returns, never nested inside its event drain.
      @stream.on_utterance { |utterance| @pending << utterance.text unless utterance.text.blank? }
    end

    # The running conversation transcript (user and assistant turns in order).
    def transcript : Array(Turn)
      @transcript
    end

    # True while the assistant's reply is being synthesized/streamed.
    def speaking? : Bool
      @speaking
    end

    # Fired when the user finishes an utterance (their turn).
    def on_user_turn(&block : String ->) : Nil
      @user_listeners << block
    end

    # Fired with the assistant's full reply text once the responder returns.
    def on_assistant_turn(&block : String ->) : Nil
      @assistant_listeners << block
    end

    # Fired per PCM chunk of the assistant's spoken reply — the app plays each
    # immediately (low latency). See `SpeechChunkEvent#pcm`.
    def on_speech_chunk(&block : SpeechChunkEvent ->) : Nil
      @chunk_listeners << block
    end

    # Feeds captured microphone PCM (16 kHz mono Float32). When it completes a
    # user utterance, the responder runs and the reply is spoken — all before
    # this returns.
    def push_audio(samples : Slice(Float32)) : Nil
      @stream.push(samples)
      drain_pending
    end

    # Cancels the assistant's in-flight spoken reply (barge-in). Call this from
    # the app's mic/VAD thread the instant the user starts talking over the
    # assistant.
    def barge_in : Nil
      @audio.cancel_speech
    end

    # Flushes the STT stream (responding to any final utterance) and returns
    # the full transcript.
    def finish : Array(Turn)
      @stream.finish unless @stream.finished?
      drain_pending
      @transcript
    end

    def close : Nil
      @stream.close
    end

    # Responds to every utterance queued during the last stream call — run
    # AFTER that call returns so each blocking `speak` is not nested in the
    # stream's event drain.
    private def drain_pending : Nil
      while user_text = @pending.shift?
        take_turn(user_text)
      end
    end

    private def take_turn(user_text : String) : Nil
      @transcript << Turn.new("user", user_text)
      @user_listeners.each(&.call(user_text))

      reply = @responder.call(user_text)
      @transcript << Turn.new("assistant", reply)
      @assistant_listeners.each(&.call(reply))

      return if reply.blank?
      @speaking = true
      begin
        @audio.speak_streaming(reply, voice: @voice) do |chunk|
          @chunk_listeners.each(&.call(chunk))
        end
      ensure
        @speaking = false
      end
    end
  end
end
