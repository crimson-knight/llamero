require "../spec_helper"

private CONVO_HALF_SECOND = 8_000

private def silence(count : Int32 = CONVO_HALF_SECOND) : Slice(Float32)
  Slice(Float32).new(count, 0.0_f32)
end

private def convo_setup
  bridge = Llamero::Native::MockAudioBridge.new
  runtime = Llamero::Native::AudioRuntime.new(bridge: bridge)
  {runtime, bridge}
end

describe Llamero::Native::ConversationSession do
  it "runs a turn: user utterance -> responder -> streamed spoken reply" do
    runtime, bridge = convo_setup
    bridge.scripted_utterances << "what time is it" # 4 words

    user_said : String? = nil
    assistant_said : String? = nil
    chunks = 0

    convo = runtime.start_conversation { |text| "you said #{text}" }
    convo.on_user_turn { |text| user_said = text }
    convo.on_assistant_turn { |text| assistant_said = text }
    convo.on_speech_chunk { |_chunk| chunks += 1 }

    4.times { convo.push_audio(silence) } # complete the utterance

    user_said.should eq("what time is it")
    assistant_said.should eq("you said what time is it")
    chunks.should be > 0
    convo.transcript.map(&.role).should eq(["user", "assistant"])
    convo.transcript.map(&.text).should eq(["what time is it", "you said what time is it"])
  end

  it "keeps a running transcript across multiple turns" do
    runtime, bridge = convo_setup
    bridge.scripted_utterances << "hello"       # 1 word
    bridge.scripted_utterances << "how are you" # 3 words

    convo = runtime.start_conversation { |text| "reply to #{text}" }
    convo.push_audio(silence)             # "hello" completes
    3.times { convo.push_audio(silence) } # "how are you" completes

    convo.transcript.map(&.role).should eq(["user", "assistant", "user", "assistant"])
    convo.transcript[2].text.should eq("how are you")
  end

  it "supports barge-in: cancelling the reply mid-stream" do
    runtime, bridge = convo_setup
    bridge.scripted_utterances << "hi"

    chunks = 0
    convo = runtime.start_conversation { |_text| "One. Two. Three. Four." }
    convo.on_speech_chunk do |_chunk|
      chunks += 1
      convo.barge_in if chunks == 1 # user cuts in after the first sentence
    end

    convo.push_audio(silence) # "hi" completes -> reply streams, then barge-in

    chunks.should eq(1)
    convo.speaking?.should be_false
  end

  it "journals the user side of the conversation" do
    path = File.join(Dir.tempdir, "llamero-convo-#{Random.rand(1_000_000)}.jsonl")
    runtime, bridge = convo_setup
    bridge.scripted_utterances << "remember this"

    convo = runtime.start_conversation(journal: path) { |text| "ok" }
    2.times { convo.push_audio(silence) }

    Llamero::Native::TranscriptJournal.read(path).map(&.text).should eq(["remember this"])
  ensure
    File.delete(path) if path && File.exists?(path)
  end
end
