require "../spec_helper"

private MEETING_HALF_SECOND = 8_000

private def silence(count : Int32 = MEETING_HALF_SECOND) : Slice(Float32)
  Slice(Float32).new(count, 0.0_f32)
end

private def meeting_setup
  bridge = Llamero::Native::MockAudioBridge.new
  runtime = Llamero::Native::AudioRuntime.new(bridge: bridge)
  {runtime, bridge}
end

describe Llamero::Native::MeetingSession do
  it "attributes each source to its speaker label" do
    runtime, bridge = meeting_setup
    bridge.scripted_utterances_by_source["Me"] = ["hello team"]          # 2 words
    bridge.scripted_utterances_by_source["Them"] = ["hi there everyone"] # 3 words

    meeting = runtime.start_meeting
    lines = [] of Llamero::Native::MeetingSession::Line
    meeting.on_line { |line| lines << line }

    2.times { meeting.push_me(silence) }
    3.times { meeting.push_them(silence) }
    transcript = meeting.finish

    attributed = lines.map { |l| {l.speaker, l.text} }
    attributed.should contain({"Me", "hello team"})
    attributed.should contain({"Them", "hi there everyone"})
    transcript.size.should eq(2)
  end

  it "honors custom speaker labels" do
    runtime, bridge = meeting_setup
    bridge.scripted_utterances_by_source["Agent"] = ["how can i help"]    # 4 words
    bridge.scripted_utterances_by_source["Caller"] = ["my order is late"] # 4 words

    meeting = runtime.start_meeting(me_label: "Agent", them_label: "Caller")
    meeting.me_label.should eq("Agent")
    meeting.them_label.should eq("Caller")

    4.times { meeting.push_me(silence) }
    4.times { meeting.push_them(silence) }
    lines = meeting.finish

    lines.map(&.speaker).sort.should eq(["Agent", "Caller"])
    lines.find { |l| l.speaker == "Caller" }.not_nil!.text.should eq("my order is late")
  end

  it "journals merged attributed lines durably — a crash before finish keeps them" do
    path = File.join(Dir.tempdir, "llamero-meeting-#{Random.rand(1_000_000)}.jsonl")
    runtime, bridge = meeting_setup
    bridge.scripted_utterances_by_source["Me"] = ["one two"]
    bridge.scripted_utterances_by_source["Them"] = ["three four five"]

    meeting = runtime.start_meeting(journal: path)
    2.times { meeting.push_me(silence) }
    3.times { meeting.push_them(silence) }
    # Simulate a crash: never call finish. The journal is already fsync'd.

    entries = Llamero::Native::TranscriptJournal.read(path)
    entries.map(&.text).sort.should eq(["one two", "three four five"])
    entries.compact_map(&.source).sort.should eq(["Me", "Them"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end

  it "returns the full merged transcript on finish" do
    runtime, bridge = meeting_setup
    bridge.scripted_utterances_by_source["Me"] = ["good morning"]
    bridge.scripted_utterances_by_source["Them"] = ["good morning to you"]

    meeting = runtime.start_meeting
    2.times { meeting.push_me(silence) }
    4.times { meeting.push_them(silence) }
    transcript = meeting.finish

    transcript.map(&.text).should contain("good morning")
    transcript.map(&.text).should contain("good morning to you")
  end
end
