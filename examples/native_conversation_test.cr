# Full voice-conversation loop: streaming STT -> responder -> streaming TTS.
# Simulates the mic by reading a 16kHz mono WAV, runs it through a
# ConversationSession with a canned responder (swap in a real LLM for your
# app), and reports the user turn, the assistant reply, and the streamed
# speech chunks.
#
# Build the bridge first:  cd native/llamero-audio && ./build.sh
# Make a clip:  say -o /tmp/turn.wav --data-format=LEF32@16000 "What is the capital of France?"
# Run:  crystal run examples/native_conversation_test.cr -- /tmp/turn.wav
require "../src/llamero"

SAMPLE_RATE   = 16_000
CHUNK_SAMPLES = SAMPLE_RATE // 2

def read_wav_samples(path : String) : Slice(Float32)
  File.open(path) do |file|
    abort "#{path} is not RIFF" unless file.read_string(4) == "RIFF"
    file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    abort "#{path} is not WAVE" unless file.read_string(4) == "WAVE"
    audio_format = 0_u16; channels = 0_u16; sample_rate = 0_u32
    bits = 0_u16; data = Bytes.empty
    loop do
      id = file.read_string(4)
      size = file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      case id
      when "fmt "
        audio_format = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        channels = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        sample_rate = file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        file.skip(6); bits = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        file.skip(size - 16) if size > 16
      when "data"
        data = Bytes.new(size); file.read_fully(data); break
      else
        file.skip(size)
      end
    end
    abort "expected 16kHz mono" unless channels == 1 && sample_rate == SAMPLE_RATE
    io = IO::Memory.new(data)
    case {audio_format, bits}
    when {3_u16, 32_u16}
      Slice(Float32).new(data.size // 4) { io.read_bytes(Float32, IO::ByteFormat::LittleEndian) }
    when {1_u16, 16_u16}
      Slice(Float32).new(data.size // 2) { io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_f32 / 32_768.0_f32 }
    else
      abort "unsupported WAV encoding"
    end
  end
end

path = ARGV[0]? || abort "usage: crystal run examples/native_conversation_test.cr -- /path/to/16k-mono.wav"
abort "not found: #{path}" unless File.exists?(path)

bridge = Llamero::Native::AudioFFIBridge.try_load
abort "build the bridge first: cd native/llamero-audio && ./build.sh" unless bridge
puts "bridge: #{bridge.name}"

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)

# Your reply logic goes here — swap this canned responder for a local
# ModelSession or a cloud Llamero::Client.
convo = audio.start_conversation do |user_text|
  "I heard you say: #{user_text}. Here is a short spoken reply."
end

convo.on_user_turn { |text| puts "\n  user: #{text}" }
convo.on_assistant_turn { |text| puts "  assistant: #{text}" }
reply_chunks = 0
reply_samples = 0
convo.on_speech_chunk do |chunk|
  reply_chunks += 1
  reply_samples += chunk.pcm.size // 2
  puts "    ♪ reply chunk #{chunk.chunk_index} (#{chunk.pcm.size // 2} samples)#{chunk.final? ? " [final]" : ""}"
end

samples = read_wav_samples(path)
puts "feeding #{(samples.size / SAMPLE_RATE.to_f).round(1)}s of mic audio..."
offset = 0
while offset < samples.size
  count = Math.min(CHUNK_SAMPLES, samples.size - offset)
  convo.push_audio(samples[offset, count]); offset += count
end
convo.finish

puts "\n=== transcript ==="
convo.transcript.each { |turn| puts "  #{turn.role}: #{turn.text}" }
puts "\nassistant reply streamed as #{reply_chunks} chunks (#{reply_samples} samples)"
audio.close
