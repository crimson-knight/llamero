require "json"
require "./audio_stream"
require "./transcript_journal"

module Llamero::Native
  # A live meeting-transcription session over TWO labeled audio sources — the
  # local microphone ("Me") and the system/remote audio ("Them") — merged into
  # one time-ordered, speaker-attributed transcript.
  #
  # The channel IS the speaker: anything captured from the mic is the user;
  # anything from the system output is the remote party. For the common 1:1
  # call this is far more reliable than acoustic diarization (no clustering, no
  # confusion). For multi-party remote audio, run offline `transcribe_diarized`
  # over a saved system-channel recording to split "Them" further.
  #
  # The app owns capture (macOS: a Core Audio process tap for system audio,
  # `AVAudioEngine` for the mic — see
  # `development_docs/audio_conversation_roadmap.md`) and feeds each source's
  # 16 kHz mono Float32 samples to the matching side.
  #
  # ```
  # audio = Llamero::Native::AudioRuntime.new
  # meeting = audio.start_meeting(journal: Path["~/.llamero/meetings/today.jsonl"])
  # meeting.on_line { |line| puts "#{line.speaker}: #{line.text}" }
  #
  # # app capture loop, two sources:
  # meeting.push_me(mic_samples)      # attributed to "Me"
  # meeting.push_them(system_samples) # attributed to "Them"
  #
  # transcript = meeting.finish # Array(MeetingSession::Line), time-ordered
  # ```
  #
  # Crash-safety: when opened with a `journal:`, every confirmed line is
  # appended and fsync'd the instant it is detected (recover with
  # `TranscriptJournal.read`).
  class MeetingSession
    # One speaker-attributed line of meeting transcript. Timestamps are
    # millisecond offsets within that line's own source stream.
    struct Line
      getter speaker : String
      getter text : String
      getter start_ms : Float64?
      getter end_ms : Float64?

      def initialize(@speaker : String, @text : String, @start_ms : Float64? = nil,
                     @end_ms : Float64? = nil)
      end
    end

    getter me_label : String
    getter them_label : String

    # :nodoc: Use `AudioRuntime#start_meeting`.
    def initialize(
      @me_stream : AudioStream,
      @them_stream : AudioStream,
      @me_label : String,
      @them_label : String,
      @journal : TranscriptJournal? = nil,
    )
      @lines = [] of Line
      @line_listeners = [] of Line ->
      @me_stream.on_utterance { |utterance| record(@me_label, utterance) }
      @them_stream.on_utterance { |utterance| record(@them_label, utterance) }
    end

    # Registers a listener fired once per confirmed, attributed line (in the
    # order utterances are detected across both sources).
    def on_line(&block : Line ->) : Nil
      @line_listeners << block
    end

    # Pushes local-microphone samples (16 kHz mono Float32) → "Me".
    def push_me(samples : Slice(Float32)) : Nil
      @me_stream.push(samples)
    end

    # Pushes system/remote samples (16 kHz mono Float32) → "Them".
    def push_them(samples : Slice(Float32)) : Nil
      @them_stream.push(samples)
    end

    # The merged transcript so far, ordered by each line's start time. Lines
    # from different sources are interleaved by their per-stream start_ms,
    # which lines up when the app pushes both sources in real time.
    def transcript : Array(Line)
      @lines.sort_by { |line| line.start_ms || 0.0 }
    end

    # Flushes both sources (emitting any trailing utterances), closes the
    # journal, and returns the final merged transcript.
    def finish : Array(Line)
      @me_stream.finish unless @me_stream.finished?
      @them_stream.finish unless @them_stream.finished?
      @journal.try(&.close)
      transcript
    end

    # Abandons both streams without flushing (and closes the journal). Use on
    # error paths; `finish` is the normal exit.
    def close : Nil
      @me_stream.close
      @them_stream.close
      @journal.try(&.close)
    end

    private def record(speaker : String, utterance : Utterance) : Nil
      line = Line.new(speaker, utterance.text, utterance.start_ms, utterance.end_ms)
      # Persist BEFORE listeners: a crash/raise must not lose a confirmed line.
      @journal.try(&.append(utterance.text, utterance.start_ms, utterance.end_ms, speaker))
      @lines << line
      @line_listeners.each(&.call(line))
    end
  end
end
