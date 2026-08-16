require "../spec_helper"

private def speak_setup
  bridge = Llamero::Native::MockAudioBridge.new
  runtime = Llamero::Native::AudioRuntime.new(bridge: bridge)
  {runtime, bridge}
end

describe "streaming text-to-speech" do
  it "yields one speech chunk per sentence and returns the completed audio" do
    runtime, _bridge = speak_setup
    chunks = [] of Llamero::Native::SpeechChunkEvent
    result = runtime.speak_streaming("First sentence. Second one! Third?") do |chunk|
      chunks << chunk
    end

    chunks.size.should eq(3)
    chunks.map(&.chunk_index).should eq([0, 1, 2])
    chunks.last.final?.should be_true
    chunks.first.final?.should be_false
    chunks.each { |chunk| chunk.sample_rate.should eq(16_000) } # mock rate
    chunks.each { |chunk| chunk.pcm.size.should be > 0 }        # decodable PCM
    result.should_not be_nil
    result.not_nil!.sample_rate.should eq(16_000)
  end

  it "decodes chunk PCM as little-endian 16-bit samples" do
    runtime, _bridge = speak_setup
    first : Llamero::Native::SpeechChunkEvent? = nil
    runtime.speak_streaming("Hello world here") { |chunk| first ||= chunk }
    (first.not_nil!.pcm.size % 2).should eq(0)
  end

  it "stops on barge-in and returns nil" do
    runtime, _bridge = speak_setup
    seen = [] of Int32
    result = runtime.speak_streaming("One. Two. Three. Four.") do |chunk|
      seen << chunk.chunk_index
      runtime.cancel_speech if seen.size == 1 # barge-in after the first sentence
    end

    result.should be_nil
    seen.should eq([0]) # never synthesized the second sentence
  end

  it "fires a speech_cancelled event on barge-in" do
    runtime, _bridge = speak_setup
    events = [] of Llamero::Native::AudioEvent
    runtime.on_event { |event| events << event }

    runtime.speak_streaming("Alpha. Bravo. Charlie.") do |chunk|
      runtime.cancel_speech if chunk.chunk_index == 0
    end

    events.any?(Llamero::Native::SpeechCancelledEvent).should be_true
  end

  it "rejects empty text" do
    runtime, _bridge = speak_setup
    expect_raises(Llamero::Native::SpeechSynthesisError, /empty/) do
      runtime.speak_streaming("") { }
    end
  end

  it "leaves non-streaming speak unchanged" do
    runtime, _bridge = speak_setup
    spoken = runtime.speak("plain old speak")
    spoken.sample_rate.should eq(16_000)
    File.exists?(spoken.path).should be_true
  end
end
