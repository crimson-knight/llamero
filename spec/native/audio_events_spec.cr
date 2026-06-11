require "../spec_helper"

describe Llamero::Native::AudioEvent do
  it "parses transcript_final frames with segments" do
    frame = {
      "event"              => "transcript_final",
      "session_id"         => "audio-runtime-1",
      "created_at"         => "2026-06-11T12:00:00Z",
      "text"               => "hello world",
      "segments"           => [
        {"text" => "hello", "start_ms" => 0.0, "end_ms" => 400.0},
        {"text" => "world", "start_ms" => 500.0, "end_ms" => 900.0},
      ],
      "duration_ms"        => 900.0,
      "processing_time_ms" => 12.5,
      "confidence"         => 0.97,
    }.to_json

    event = Llamero::Native::AudioEvent.from_bridge_json(frame)
    event.should be_a(Llamero::Native::TranscriptFinalEvent)
    transcript = event.as(Llamero::Native::TranscriptFinalEvent)

    transcript.session_id.should eq("audio-runtime-1")
    transcript.text.should eq("hello world")
    transcript.segments.size.should eq(2)
    transcript.segments[0].text.should eq("hello")
    transcript.segments[0].start_ms.should eq(0.0)
    transcript.segments[1].end_ms.should eq(900.0)
    transcript.duration_ms.should eq(900.0)
    transcript.processing_time_ms.should eq(12.5)
    transcript.confidence.should eq(0.97)
    transcript.language.should be_nil
  end

  it "parses asr model load lifecycle frames" do
    started = Llamero::Native::AudioEvent.from_bridge_json(
      {"event" => "asr_model_load_started", "model_version" => "v2"}.to_json
    )
    started.should be_a(Llamero::Native::AsrModelLoadStartedEvent)
    started.as(Llamero::Native::AsrModelLoadStartedEvent).model_version.should eq("v2")

    progress = Llamero::Native::AudioEvent.from_bridge_json(
      {"event" => "asr_model_load_progress", "progress" => 0.42}.to_json
    )
    progress.as(Llamero::Native::AsrModelLoadProgressEvent).progress.should eq(0.42)

    loaded = Llamero::Native::AudioEvent.from_bridge_json(
      {"event" => "asr_model_loaded", "model_version" => "v3", "load_time_ms" => 1234.0}.to_json
    )
    loaded.as(Llamero::Native::AsrModelLoadedEvent).load_time_ms.should eq(1234.0)
  end

  it "parses speak_completed frames" do
    event = Llamero::Native::AudioEvent.from_bridge_json({
      "event"             => "speak_completed",
      "path"              => "/tmp/out.wav",
      "duration_ms"       => 1500.0,
      "synthesis_time_ms" => 80.0,
      "sample_rate"       => 24_000,
    }.to_json)

    completed = event.as(Llamero::Native::SpeakCompletedEvent)
    completed.path.should eq("/tmp/out.wav")
    completed.duration_ms.should eq(1500.0)
    completed.synthesis_time_ms.should eq(80.0)
    completed.sample_rate.should eq(24_000)
  end

  it "parses error frames into typed audio errors" do
    transcription_error = Llamero::Native::AudioEvent.from_bridge_json({
      "event" => "error", "message" => "boom",
      "code" => "transcription_failed", "recoverable" => true,
    }.to_json).as(Llamero::Native::AudioErrorEvent)

    transcription_error.to_error.should be_a(Llamero::Native::TranscriptionError)
    transcription_error.to_error.message.should eq("boom")
    transcription_error.recoverable.should be_true

    speak_error = Llamero::Native::AudioEvent.from_bridge_json({
      "event" => "error", "message" => "no voice",
      "code" => "speak_failed", "recoverable" => true,
    }.to_json).as(Llamero::Native::AudioErrorEvent)
    speak_error.to_error.should be_a(Llamero::Native::SpeechSynthesisError)

    other_error = Llamero::Native::AudioEvent.from_bridge_json({
      "event" => "error", "message" => "odd", "code" => "something_else",
    }.to_json).as(Llamero::Native::AudioErrorEvent)
    other_error.to_error.class.should eq(Llamero::Native::AudioError)
    other_error.to_error.code.should eq("something_else")
  end

  it "surfaces unrecognized frames as UnknownAudioEvent" do
    event = Llamero::Native::AudioEvent.from_bridge_json(
      {"event" => "vad_state", "speaking" => true}.to_json
    )
    event.should be_a(Llamero::Native::UnknownAudioEvent)
    event.raw["speaking"].as_bool.should be_true
  end
end
