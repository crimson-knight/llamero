# Streaming STT (live dictation) smoke test: simulates a microphone by
# reading a 16kHz mono WAV file and pushing it through an AudioStream in
# 0.5s chunks, printing partial hypotheses as a live-updating line and
# EOU-detected utterances as completed lines, then finishing for the full
# session transcript.
#
# Build the bridge first:
#   cd native/llamero-audio && ./build.sh
#
# Make a test file with pauses (EOU needs ~1.3s of silence between phrases):
#   say -o /tmp/dictation.wav --data-format=LEF32@16000 \
#     "This is the first sentence. [[slnc 2000]] And here is the second one."
#
# Then run it (first run downloads the Parakeet EOU streaming models):
#   crystal run examples/native_dictation_test.cr -- /tmp/dictation.wav
#
# Verifies the audio-track Phase 3 claims:
#   1. Pushed PCM streams back transcript partials in near real time.
#   2. Utterance boundaries arrive via Parakeet EOU detection.
#   3. finish() flushes and returns the full session transcript.
require "../src/llamero"

SAMPLE_RATE  = 16_000
CHUNK_SAMPLES = SAMPLE_RATE // 2 # 0.5s per push, like a capture callback

# Minimal RIFF/WAVE reader for the formats we care about: 16kHz mono, either
# IEEE Float32 (what `say --data-format=LEF32@16000` writes) or PCM16.
def read_wav_samples(path : String) : Slice(Float32)
  File.open(path) do |file|
    abort "#{path} is not a RIFF file" unless file.read_string(4) == "RIFF"
    file.read_bytes(UInt32, IO::ByteFormat::LittleEndian) # overall size
    abort "#{path} is not a WAVE file" unless file.read_string(4) == "WAVE"

    audio_format = 0_u16
    channels = 0_u16
    sample_rate = 0_u32
    bits_per_sample = 0_u16
    data = Bytes.empty

    # Walk the chunks; macOS writes extra ones (e.g. FLLR) before data.
    loop do
      chunk_id = file.read_string(4)
      chunk_size = file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      case chunk_id
      when "fmt "
        audio_format = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        channels = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        sample_rate = file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
        file.skip(6) # byte rate + block align
        bits_per_sample = file.read_bytes(UInt16, IO::ByteFormat::LittleEndian)
        file.skip(chunk_size - 16) if chunk_size > 16
      when "data"
        data = Bytes.new(chunk_size)
        file.read_fully(data)
        break
      else
        file.skip(chunk_size)
      end
    end

    abort "expected mono audio, got #{channels} channels" unless channels == 1
    unless sample_rate == SAMPLE_RATE
      abort "expected #{SAMPLE_RATE}Hz audio, got #{sample_rate}Hz " \
            "(resample with: ffmpeg -i in.wav -ar 16000 -ac 1 out.wav)"
    end

    io = IO::Memory.new(data)
    case {audio_format, bits_per_sample}
    when {3_u16, 32_u16} # IEEE Float32
      Slice(Float32).new(data.size // 4) { io.read_bytes(Float32, IO::ByteFormat::LittleEndian) }
    when {1_u16, 16_u16} # PCM16 -> Float32
      Slice(Float32).new(data.size // 2) do
        io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_f32 / 32_768.0_f32
      end
    else
      abort "unsupported WAV encoding (format #{audio_format}, #{bits_per_sample}-bit); " \
            "use Float32 or PCM16"
    end
  end
end

audio_path = ARGV[0]?
unless audio_path
  abort "usage: crystal run examples/native_dictation_test.cr -- /path/to/speech-16kHz-mono.wav"
end
unless File.exists?(audio_path)
  abort "audio file not found: #{audio_path}"
end

bridge = Llamero::Native::AudioFFIBridge.try_load
unless bridge
  abort "Audio bridge dylib not found. Build it with: cd native/llamero-audio && ./build.sh " \
        "(or set LLAMERO_AUDIO_LIB to the dylib path)"
end

puts "bridge: #{bridge.name} (#{bridge.library_path})"

samples = read_wav_samples(audio_path)
puts "audio: #{samples.size} samples (#{(samples.size / SAMPLE_RATE.to_f).round(1)}s at #{SAMPLE_RATE}Hz)"

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)

audio.on_event do |event|
  case event
  when Llamero::Native::AsrModelLoadStartedEvent
    puts "loading Parakeet #{event.model_version} streaming models (first run downloads from HuggingFace)..."
  when Llamero::Native::AsrModelLoadProgressEvent
    print "\rstreaming model download/load: #{(event.progress * 100).round(1)}%   "
    STDOUT.flush
  when Llamero::Native::AsrModelLoadedEvent
    puts "\nstreaming models loaded in #{event.load_time_ms.round(0)}ms"
  end
end

stream = audio.start_stream # chunk_ms: 160 (lowest latency), eou_debounce_ms: 1280

stream.on_partial do |text|
  # Live-updating dictation line (the in-progress utterance).
  print "\r  … #{text}\e[K"
  STDOUT.flush
end

stream.on_utterance do |utterance|
  # A confirmed end of utterance: promote the live line to a completed one.
  stamp = utterance.end_ms.try { |ms| " [#{(ms / 1000).round(1)}s]" } || ""
  print "\r\e[K"
  puts "  • #{utterance.text}#{stamp}"
end

puts "streaming #{CHUNK_SAMPLES} samples (0.5s) per push..."
started = Time.instant

offset = 0
while offset < samples.size
  count = Math.min(CHUNK_SAMPLES, samples.size - offset)
  stream.push(samples[offset, count])
  offset += count
  sleep 50.milliseconds # simulated capture pacing
end

result = stream.finish
elapsed = Time.instant - started

print "\r\e[K"
puts
puts "full transcript: #{result.text}"
puts "utterances: #{result.segments.size}"
result.segments.each do |segment|
  puts "  #{(segment.start_ms / 1000).round(1)}s-#{(segment.end_ms / 1000).round(1)}s: #{segment.text}"
end
puts "audio duration: #{(result.duration_ms / 1000).round(1)}s, wall time: #{elapsed.total_seconds.round(1)}s"

audio.close
