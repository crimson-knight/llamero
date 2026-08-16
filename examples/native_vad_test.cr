# VAD smoke test: feed a 16kHz mono WAV through the Silero voice-activity
# detector and print speech-start / speech-end events. Verifies the VAD bridge
# (the basis for barge-in).
#
# Build the bridge first:  cd native/llamero-audio && ./build.sh
# Make a clip:  say -o /tmp/vad.wav --data-format=LEF32@16000 "Hello, this is a test of voice activity detection."
# Run:  crystal run examples/native_vad_test.cr -- /tmp/vad.wav
require "../src/llamero"

SAMPLE_RATE = 16_000
VAD_WINDOW  =  4_096

def read_wav_samples(path : String) : Slice(Float32)
  File.open(path) do |file|
    abort "#{path} is not a RIFF file" unless file.read_string(4) == "RIFF"
    file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    abort "#{path} is not a WAVE file" unless file.read_string(4) == "WAVE"
    audio_format = 0_u16; channels = 0_u16; sample_rate = 0_u32
    bits_per_sample = 0_u16; data = Bytes.empty
    loop do
      chunk_id = file.read_string(4)
      chunk_size = file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      case chunk_id
      when "fmt "
        audio_format = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        channels = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        sample_rate = file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        file.skip(6)
        bits_per_sample = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        file.skip(chunk_size - 16) if chunk_size > 16
      when "data"
        data = Bytes.new(chunk_size); file.read_fully(data); break
      else
        file.skip(chunk_size)
      end
    end
    abort "expected mono" unless channels == 1
    abort "expected #{SAMPLE_RATE}Hz, got #{sample_rate}Hz" unless sample_rate == SAMPLE_RATE
    io = IO::Memory.new(data)
    case {audio_format, bits_per_sample}
    when {3_u16, 32_u16}
      Slice(Float32).new(data.size // 4) { io.read_bytes(Float32, IO::ByteFormat::LittleEndian) }
    when {1_u16, 16_u16}
      Slice(Float32).new(data.size // 2) { io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_f32 / 32_768.0_f32 }
    else
      abort "unsupported WAV encoding"
    end
  end
end

path = ARGV[0]? || abort "usage: crystal run examples/native_vad_test.cr -- /path/to/16k-mono.wav"
abort "not found: #{path}" unless File.exists?(path)

bridge = Llamero::Native::AudioFFIBridge.try_load
abort "build the bridge first: cd native/llamero-audio && ./build.sh" unless bridge
puts "bridge: #{bridge.name}"

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)
audio.on_event do |event|
  case event
  when Llamero::Native::VadModelLoadStartedEvent then puts "loading Silero VAD (first run downloads)..."
  when Llamero::Native::VadModelLoadedEvent      then puts "VAD loaded in #{event.load_time_ms.round(0)}ms"
  end
end

vad = audio.start_vad
starts = 0
ends = 0
vad.on_speech_started { |e| starts += 1; puts "  ▶ speech STARTED @ #{(e.time_ms / 1000).round(2)}s (p=#{e.probability.round(2)})" }
vad.on_speech_ended { |e| ends += 1; puts "  ⏹ speech ENDED   @ #{(e.time_ms / 1000).round(2)}s" }

samples = read_wav_samples(path)
puts "audio: #{(samples.size / SAMPLE_RATE.to_f).round(1)}s"
offset = 0
while offset < samples.size
  count = Math.min(VAD_WINDOW, samples.size - offset)
  vad.push(samples[offset, count]); offset += count
end
# Trailing silence so the final speech segment closes.
6.times { vad.push(Slice(Float32).new(VAD_WINDOW, 0.0_f32)) }

puts "\nspeech_started events: #{starts}, speech_ended events: #{ends}"
vad.close
audio.close
