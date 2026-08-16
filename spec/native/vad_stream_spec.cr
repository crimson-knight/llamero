require "../spec_helper"

private VAD_CHUNK = 4_096

private def loud(count : Int32 = VAD_CHUNK) : Slice(Float32)
  Slice(Float32).new(count, 0.5_f32) # peak 0.5 > mock cutoff 0.1 => speech
end

private def quiet(count : Int32 = VAD_CHUNK) : Slice(Float32)
  Slice(Float32).new(count, 0.0_f32)
end

private def vad_setup
  bridge = Llamero::Native::MockAudioBridge.new
  runtime = Llamero::Native::AudioRuntime.new(bridge: bridge)
  {runtime, bridge}
end

describe Llamero::Native::VadStream do
  it "fires speech_started on the silence->speech transition" do
    runtime, _bridge = vad_setup
    starts = [] of Llamero::Native::SpeechStartedEvent
    vad = runtime.start_vad
    vad.on_speech_started { |event| starts << event }

    vad.push(quiet) # silence: nothing
    vad.push(loud)  # onset: one speech_started
    vad.push(loud)  # still speaking: no repeat

    starts.size.should eq(1)
  end

  it "fires speech_ended on the speech->silence transition" do
    runtime, _bridge = vad_setup
    ends = [] of Llamero::Native::SpeechEndedEvent
    vad = runtime.start_vad
    vad.on_speech_ended { |event| ends << event }

    vad.push(loud)  # start
    vad.push(quiet) # stop: one speech_ended

    ends.size.should eq(1)
  end

  it "loads the VAD model lazily, once per runtime, with events" do
    runtime, _bridge = vad_setup
    events = [] of Llamero::Native::AudioEvent
    runtime.on_event { |event| events << event }

    vad = runtime.start_vad
    vad.push(loud)
    vad.push(quiet)

    events.count(&.is_a?(Llamero::Native::VadModelLoadStartedEvent)).should eq(1)
    events.count(&.is_a?(Llamero::Native::VadModelLoadedEvent)).should eq(1)
  end

  it "supports the barge-in pattern: VAD start cancels speech" do
    runtime, _bridge = vad_setup
    cancelled = false
    vad = runtime.start_vad
    # Wire VAD onset -> cancel, exactly as an app would for barge-in.
    vad.on_speech_started { runtime.cancel_speech; cancelled = true }

    vad.push(loud)
    cancelled.should be_true
  end

  it "rejects pushes after close" do
    runtime, _bridge = vad_setup
    vad = runtime.start_vad
    vad.close
    vad.close # idempotent
    expect_raises(Llamero::Native::SessionStateError, /closed/) do
      vad.push(loud)
    end
  end

  it "closes open VAD streams when the runtime closes" do
    runtime, _bridge = vad_setup
    vad = runtime.start_vad
    vad.push(loud)
    runtime.close
    vad.closed?.should be_true
  end
end
