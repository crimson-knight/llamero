require "../spec_helper"

# 0.5 seconds of 16kHz mono silence - the unit the dictation example pushes.
private HALF_SECOND_SAMPLES = 8_000

private def silence(count : Int32 = HALF_SECOND_SAMPLES) : Slice(Float32)
  Slice(Float32).new(count, 0.0_f32)
end

private def mock_stream_setup
  bridge = Llamero::Native::MockAudioBridge.new
  runtime = Llamero::Native::AudioRuntime.new(bridge: bridge)
  {runtime, bridge}
end

describe Llamero::Native::AudioStream do
  it "opens a stream with the documented defaults" do
    runtime, _bridge = mock_stream_setup
    stream = runtime.start_stream

    stream.chunk_ms.should eq(160)
    stream.eou_debounce_ms.should eq(1280)
    stream.finished?.should be_false
    stream.closed?.should be_false
  end

  it "rejects unsupported stream configurations" do
    runtime, _bridge = mock_stream_setup

    expect_raises(ArgumentError, /chunk_ms/) do
      runtime.start_stream(chunk_ms: 500)
    end
    expect_raises(ArgumentError, /eou_debounce_ms/) do
      runtime.start_stream(eou_debounce_ms: -1)
    end
  end

  it "fires partial then utterance callbacks in order on the calling fiber" do
    runtime, bridge = mock_stream_setup
    bridge.scripted_utterances << "hello there world"

    calling_fiber = Fiber.current
    sequence = [] of String

    stream = runtime.start_stream
    stream.on_partial do |text|
      Fiber.current.should eq(calling_fiber)
      sequence << "partial:#{text}"
    end
    stream.on_utterance do |utterance|
      Fiber.current.should eq(calling_fiber)
      sequence << "utterance:#{utterance.text}"
    end

    3.times { stream.push(silence) }

    sequence.should eq([
      "partial:hello",
      "partial:hello there",
      "partial:hello there world",
      "utterance:hello there world",
    ])
  end

  it "round-trips scripted utterances and returns the full session text" do
    runtime, bridge = mock_stream_setup
    bridge.scripted_utterances << "first phrase"
    bridge.scripted_utterances << "second phrase here"

    stream = runtime.start_stream
    utterances = [] of Llamero::Native::Utterance
    stream.on_utterance { |utterance| utterances << utterance }

    5.times { stream.push(silence) } # 2 words + 3 words = 5 pushes
    result = stream.finish

    utterances.map(&.text).should eq(["first phrase", "second phrase here"])
    result.text.should eq("first phrase second phrase here")
    result.segments.map(&.text).should eq(["first phrase", "second phrase here"])
    result.duration_ms.should eq(5 * 500.0)
  end

  it "derives utterance timestamps from pushed sample counts" do
    runtime, bridge = mock_stream_setup
    bridge.scripted_utterances << "hi"
    bridge.scripted_utterances << "again"

    stream = runtime.start_stream
    utterances = [] of Llamero::Native::Utterance
    stream.on_utterance { |utterance| utterances << utterance }

    2.times { stream.push(silence) } # one word per push
    stream.finish

    first = utterances[0]
    second = utterances[1]
    first.start_ms.should eq(0.0)
    first.end_ms.should eq(500.0)
    second.start_ms.should eq(500.0)
    second.end_ms.should eq(1000.0)
  end

  it "flushes an in-progress utterance on finish" do
    runtime, bridge = mock_stream_setup
    bridge.scripted_utterances << "alpha beta gamma"

    stream = runtime.start_stream
    utterances = [] of Llamero::Native::Utterance
    stream.on_utterance { |utterance| utterances << utterance }

    stream.push(silence) # only "alpha" revealed so far
    result = stream.finish

    utterances.map(&.text).should eq(["alpha beta gamma"])
    result.text.should eq("alpha beta gamma")
    stream.finished?.should be_true
    stream.closed?.should be_true
  end

  it "loads the streaming models lazily, once per runtime" do
    runtime, bridge = mock_stream_setup
    events = [] of Llamero::Native::AudioEvent
    runtime.on_event { |event| events << event }

    first = runtime.start_stream
    first.push(silence)
    first.push(silence)
    first.finish

    second = runtime.start_stream
    second.push(silence)
    second.finish

    bridge.stream_asr_loaded?(1_i64).should be_true
    events.count(&.is_a?(Llamero::Native::AsrModelLoadStartedEvent)).should eq(1)
    events.count(&.is_a?(Llamero::Native::AsrModelLoadedEvent)).should eq(1)
  end

  it "fans typed stream events out to runtime listeners" do
    runtime, bridge = mock_stream_setup
    bridge.scripted_utterances << "typed events"
    events = [] of Llamero::Native::AudioEvent
    runtime.on_event { |event| events << event }

    stream = runtime.start_stream
    2.times { stream.push(silence) }
    stream.finish

    events.any?(Llamero::Native::TranscriptPartialEvent).should be_true
    events.any?(Llamero::Native::UtteranceEndEvent).should be_true
    events.last.should be_a(Llamero::Native::TranscriptFinalEvent)
    events.each { |event| event.session_id.should_not be_empty }
  end

  it "rejects pushes and finishes after finish" do
    runtime, _bridge = mock_stream_setup
    stream = runtime.start_stream
    stream.push(silence)
    stream.finish

    expect_raises(Llamero::Native::SessionStateError, /closed|finished/) do
      stream.push(silence)
    end
    expect_raises(Llamero::Native::SessionStateError, /closed|finished/) do
      stream.finish
    end
  end

  it "rejects pushes after close" do
    runtime, _bridge = mock_stream_setup
    stream = runtime.start_stream
    stream.close
    stream.close # idempotent

    expect_raises(Llamero::Native::SessionStateError, /closed/) do
      stream.push(silence)
    end
  end

  it "closes open streams when the runtime closes" do
    runtime, _bridge = mock_stream_setup
    stream = runtime.start_stream
    stream.push(silence)

    runtime.close

    stream.closed?.should be_true
    expect_raises(Llamero::Native::SessionStateError, /closed/) do
      stream.push(silence)
    end
  end

  it "raises on a scripted push failure but the stream keeps working" do
    runtime, bridge = mock_stream_setup
    bridge.scripted_utterances << "recovered"
    bridge.fail_next_stream_push = true

    stream = runtime.start_stream
    expect_raises(Llamero::Native::TranscriptionError, /Mock stream push failure/) do
      stream.push(silence)
    end

    utterances = [] of Llamero::Native::Utterance
    stream.on_utterance { |utterance| utterances << utterance }
    stream.push(silence)
    utterances.map(&.text).should eq(["recovered"])
    stream.finish.text.should eq("recovered")
  end

  it "raises on a scripted finish failure but the runtime survives" do
    runtime, bridge = mock_stream_setup
    bridge.fail_next_stream_finish = true

    stream = runtime.start_stream
    stream.push(silence)
    expect_raises(Llamero::Native::TranscriptionError, /Mock stream finish failure/) do
      stream.finish
    end
    stream.closed?.should be_true

    # The runtime is still fully usable: new streams and one-shot calls work.
    bridge.scripted_utterances << "still alive"
    replacement = runtime.start_stream
    2.times { replacement.push(silence) }
    replacement.finish.text.should eq("still alive")
  end

  it "ignores empty pushes without touching the bridge" do
    runtime, bridge = mock_stream_setup
    stream = runtime.start_stream

    stream.push(Slice(Float32).new(0))

    bridge.stream_asr_loaded?(1_i64).should be_false
  end
end
