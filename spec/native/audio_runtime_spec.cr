require "../spec_helper"

private def with_temp_wav(&)
  path = File.join(Dir.tempdir, "llamero-audio-spec-#{Random.rand(Int32::MAX)}.wav")
  File.write(path, "fake-audio")
  begin
    yield path
  ensure
    File.delete?(path)
  end
end

private def mock_audio_runtime
  bridge = Llamero::Native::MockAudioBridge.new
  runtime = Llamero::Native::AudioRuntime.new(bridge: bridge)
  {runtime, bridge}
end

describe Llamero::Native::AudioRuntime do
  it "instantiates against the mock bridge with the documented configuration" do
    runtime = Llamero::Native::AudioRuntime.new(
      asr_model_version: "v2",
      tts_voice: "af_heart",
      bridge: Llamero::Native::MockAudioBridge.new
    )

    runtime.asr_model_version.should eq("v2")
    runtime.tts_voice.should eq("af_heart")
    runtime.bridge_name.should eq("mock")
    runtime.real_bridge?.should be_false
  end

  it "rejects unknown asr model versions" do
    expect_raises(ArgumentError, /asr_model_version/) do
      Llamero::Native::AudioRuntime.new(
        asr_model_version: "v9",
        bridge: Llamero::Native::MockAudioBridge.new
      )
    end
  end

  describe "#transcribe" do
    it "returns a deterministic transcript with word-level segments" do
      runtime, _bridge = mock_audio_runtime

      with_temp_wav do |path|
        result = runtime.transcribe(path)

        result.text.should eq("mock transcript of #{File.basename(path)}")
        result.segments.size.should eq(result.text.split.size)
        result.segments.first.text.should eq("mock")
        result.segments.first.start_ms.should eq(0.0)
        result.segments.first.end_ms.should eq(400.0)
        # Segments are ordered and non-overlapping.
        result.segments.each_cons_pair do |earlier, later|
          later.start_ms.should be >= earlier.end_ms
        end
        result.duration_ms.should eq(result.segments.last.end_ms)
        result.confidence.should eq(1.0)
      end
    end

    it "consumes scripted transcripts in order" do
      runtime, bridge = mock_audio_runtime
      bridge.scripted_transcripts << "first response"
      bridge.scripted_transcripts << "second response"

      with_temp_wav do |path|
        runtime.transcribe(path).text.should eq("first response")
        runtime.transcribe(path).text.should eq("second response")
        runtime.transcribe(path).text.should eq("mock transcript of #{File.basename(path)}")
      end
    end

    it "fails fast on missing audio files" do
      runtime, _bridge = mock_audio_runtime

      expect_raises(Llamero::Native::TranscriptionError, /not found/) do
        runtime.transcribe("/nonexistent/audio.wav")
      end
    end

    it "raises on a scripted failure but keeps the runtime usable" do
      runtime, bridge = mock_audio_runtime
      bridge.fail_next_transcription = true

      with_temp_wav do |path|
        expect_raises(Llamero::Native::TranscriptionError, /Mock transcription failure/) do
          runtime.transcribe(path)
        end

        runtime.transcribe(path).text.should eq("mock transcript of #{File.basename(path)}")
      end
    end
  end

  describe "#speak" do
    it "writes a playable WAV file at the requested path" do
      runtime, _bridge = mock_audio_runtime
      output = File.join(Dir.tempdir, "llamero-audio-spec-speak-#{Random.rand(Int32::MAX)}.wav")

      begin
        spoken = runtime.speak("hello there", output_path: output)

        spoken.path.to_s.should eq(output)
        spoken.duration_ms.should be > 0
        File.exists?(output).should be_true
        File.read(output)[0, 4].should eq("RIFF")
        File.size(output).should be >= 44
      ensure
        File.delete?(output)
      end
    end

    it "defaults to a temporary output path" do
      runtime, _bridge = mock_audio_runtime

      spoken = runtime.speak("hello")
      begin
        File.exists?(spoken.path).should be_true
        File.read(spoken.path)[0, 4].should eq("RIFF")
      ensure
        File.delete?(spoken.path)
      end
    end

    it "rejects empty text without touching the bridge" do
      runtime, _bridge = mock_audio_runtime

      expect_raises(Llamero::Native::SpeechSynthesisError, /empty/) do
        runtime.speak("   ")
      end
    end

    it "raises on a scripted failure but keeps the runtime usable" do
      runtime, bridge = mock_audio_runtime
      bridge.fail_next_speak = true

      expect_raises(Llamero::Native::SpeechSynthesisError, /Mock speech synthesis failure/) do
        runtime.speak("hello")
      end

      spoken = runtime.speak("hello again")
      begin
        File.exists?(spoken.path).should be_true
      ensure
        File.delete?(spoken.path)
      end
    end
  end

  describe "event listeners" do
    it "fans typed events out to every listener" do
      runtime, _bridge = mock_audio_runtime
      first_listener = [] of Llamero::Native::AudioEvent
      second_listener = [] of String

      runtime.on_event { |event| first_listener << event }
      runtime.on_event { |event| second_listener << event.class.name }

      with_temp_wav do |path|
        runtime.transcribe(path)
      end

      first_listener.map(&.class.name).should eq(second_listener)
      first_listener.any?(Llamero::Native::AsrModelLoadStartedEvent).should be_true
      first_listener.any?(Llamero::Native::AsrModelLoadedEvent).should be_true
      first_listener.last.should be_a(Llamero::Native::TranscriptFinalEvent)
      first_listener.each { |event| event.session_id.should_not be_empty }
    end

    it "loads asr models lazily and only once per runtime" do
      runtime, bridge = mock_audio_runtime
      events = [] of Llamero::Native::AudioEvent
      runtime.on_event { |event| events << event }

      with_temp_wav do |path|
        runtime.transcribe(path)
        runtime.transcribe(path)
      end

      events.count(&.is_a?(Llamero::Native::AsrModelLoadStartedEvent)).should eq(1)
      events.count(&.is_a?(Llamero::Native::TranscriptFinalEvent)).should eq(2)
    end
  end

  describe "#close" do
    it "refuses further work after close" do
      runtime, _bridge = mock_audio_runtime
      runtime.close
      runtime.closed?.should be_true

      with_temp_wav do |path|
        expect_raises(Llamero::Native::SessionStateError, /closed/) do
          runtime.transcribe(path)
        end
      end

      expect_raises(Llamero::Native::SessionStateError, /closed/) do
        runtime.speak("hello")
      end
    end
  end
end
