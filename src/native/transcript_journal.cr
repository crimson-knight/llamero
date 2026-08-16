require "json"

module Llamero::Native
  # A crash-safe, append-only journal of finalized streaming-transcription
  # utterances.
  #
  # llamero holds a live streaming transcript only in memory; if the host app
  # crashes mid-dictation, that transcript is gone. Open a stream with a
  # journal (`AudioRuntime#start_stream(journal: path)`) and every finalized
  # utterance is appended AND fsync'd to a JSONL file the instant it is
  # confirmed (`utterance_end`), so a crash loses at most the in-flight
  # (not-yet-ended) phrase.
  #
  # Each line is one self-contained JSON object:
  #
  # ```json
  # {"seq":0,"text":"hello there","start_ms":0.0,"end_ms":900.0,"source":"mic","created_at":"2026-06-21T..."}
  # ```
  #
  # Recover after a crash with `TranscriptJournal.read(path)` (or
  # `recover_text`), which tolerates a torn final line from a crash mid-write.
  class TranscriptJournal
    # One recovered journal entry.
    struct Entry
      include JSON::Serializable

      getter seq : Int32
      getter text : String
      getter start_ms : Float64?
      getter end_ms : Float64?
      getter source : String?
      getter created_at : String?

      def initialize(@seq : Int32, @text : String, @start_ms : Float64? = nil,
                     @end_ms : Float64? = nil, @source : String? = nil,
                     @created_at : String? = nil)
      end
    end

    getter path : Path
    # Flush + fsync after this many appends. 1 (default) fsyncs every
    # utterance — safest; raise it to trade durability for fewer syncs.
    getter fsync_every : Int32

    @file : File
    @seq : Int32 = 0
    @since_sync : Int32 = 0
    @closed = false

    # Opens (or, with `append: true`, resumes) a journal at `path`. Resuming
    # continues the sequence numbering after the last recorded entry.
    def initialize(path : Path | String, @fsync_every : Int32 = 1, append : Bool = true)
      @path = Path[path].expand
      Dir.mkdir_p(@path.dirname)
      @seq = TranscriptJournal.read(@path).size if append && File.exists?(@path)
      @file = File.new(@path.to_s, append ? "a" : "w")
    end

    # Appends one finalized utterance and (per the fsync cadence) forces it to
    # disk. Safe to call from the fiber that drives `push`/`finish`.
    def append(text : String, start_ms : Float64? = nil, end_ms : Float64? = nil,
               source : String? = nil) : Nil
      raise IO::Error.new("Transcript journal already closed") if @closed
      entry = Entry.new(@seq, text, start_ms, end_ms, source, Time.utc.to_rfc3339)
      @file.puts(entry.to_json)
      @seq += 1
      @since_sync += 1
      if @since_sync >= @fsync_every
        sync
      end
    end

    # Convenience overload: journal an `Utterance` (carrying its own source).
    def append(utterance : Utterance, source : String? = nil) : Nil
      append(utterance.text, utterance.start_ms, utterance.end_ms, source || utterance.source)
    end

    # Number of entries written by this writer so far (also the next seq).
    def size : Int32
      @seq
    end

    def closed? : Bool
      @closed
    end

    def close : Nil
      return if @closed
      @closed = true
      sync
      @file.close
    end

    private def sync : Nil
      @file.flush
      @file.fsync
      @since_sync = 0
    rescue
      # Best-effort durability: a filesystem that rejects fsync must not crash
      # a live dictation. The data is already in the OS write buffer.
    end

    # Reads back every finalized utterance from a journal file, in order.
    # Tolerates a torn/partial final line (a crash mid-write) by skipping any
    # line that does not parse.
    def self.read(path : Path | String) : Array(Entry)
      entries = [] of Entry
      return entries unless File.exists?(path)
      File.each_line(path.to_s) do |line|
        next if line.strip.empty?
        entry = Entry.from_json(line) rescue next
        entries << entry
      end
      entries
    end

    # The full recovered transcript text — utterances joined by spaces.
    def self.recover_text(path : Path | String) : String
      read(path).map(&.text).join(" ")
    end
  end
end
