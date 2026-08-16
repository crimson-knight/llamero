require "../spec_helper"

private def tmp_journal_path : String
  File.join(Dir.tempdir, "llamero-journal-#{Random.rand(1_000_000)}.jsonl")
end

describe Llamero::Native::TranscriptJournal do
  it "appends utterances and reads them back in order" do
    path = tmp_journal_path
    journal = Llamero::Native::TranscriptJournal.new(path)
    journal.append("first phrase", 0.0, 500.0, "mic")
    journal.append("second phrase", 500.0, 1200.0, "system")
    journal.close

    entries = Llamero::Native::TranscriptJournal.read(path)
    entries.map(&.text).should eq(["first phrase", "second phrase"])
    entries.map(&.seq).should eq([0, 1])
    entries.map(&.source).should eq(["mic", "system"])
    entries[0].start_ms.should eq(0.0)
    entries[1].end_ms.should eq(1200.0)
    Llamero::Native::TranscriptJournal.recover_text(path).should eq("first phrase second phrase")
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "is durable without close: data survives once appended (fsync_every: 1)" do
    path = tmp_journal_path
    journal = Llamero::Native::TranscriptJournal.new(path)
    journal.append("durable utterance")
    # Deliberately do NOT close - simulate a crash. The fsync'd line is on disk.
    Llamero::Native::TranscriptJournal.read(path).map(&.text).should eq(["durable utterance"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "tolerates a torn final line (crash mid-write)" do
    path = tmp_journal_path
    journal = Llamero::Native::TranscriptJournal.new(path)
    journal.append("complete one")
    journal.append("complete two")
    journal.close
    # Append a half-written final line (no closing brace, no newline), as a
    # crash mid-write would leave behind.
    File.open(path, "a") { |f| f.print("{\"seq\":2,\"text\":\"torn") }

    entries = Llamero::Native::TranscriptJournal.read(path)
    entries.map(&.text).should eq(["complete one", "complete two"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "resumes sequence numbering when appending to an existing journal" do
    path = tmp_journal_path
    first = Llamero::Native::TranscriptJournal.new(path)
    first.append("one")
    first.append("two")
    first.close

    second = Llamero::Native::TranscriptJournal.new(path) # append: true (default)
    second.append("three")
    second.close

    entries = Llamero::Native::TranscriptJournal.read(path)
    entries.map(&.seq).should eq([0, 1, 2])
    entries.map(&.text).should eq(["one", "two", "three"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "rejects appends after close" do
    path = tmp_journal_path
    journal = Llamero::Native::TranscriptJournal.new(path)
    journal.close
    expect_raises(IO::Error, /closed/) do
      journal.append("nope")
    end
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "returns an empty array for a missing journal" do
    Llamero::Native::TranscriptJournal.read(tmp_journal_path).should be_empty
  end
end
