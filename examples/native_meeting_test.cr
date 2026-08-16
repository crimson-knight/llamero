# Meeting-mode smoke test: dual-channel, speaker-attributed transcription.
# Simulates a call by reading TWO 16kHz mono WAVs — one for the local mic
# ("Me") and one for the system/remote audio ("Them") — and interleaving them
# into a MeetingSession in 0.5s chunks (as two real-time capture callbacks
# would). The channel IS the speaker: mic -> Me, system -> Them.
#
# Build the bridge first:
#   cd native/llamero-audio && ./build.sh
#
# Make two test files (distinct voices stand in for two people):
#   say -v Samantha -o /tmp/me.wav     --data-format=LEF32@16000 "Hey, thanks for joining. Can you walk me through the issue?"
#   say -v Daniel   -o /tmp/them.wav   --data-format=LEF32@16000 "Sure. The dashboard is not loading the latest numbers."
#
# Then run it:
#   crystal run examples/native_meeting_test.cr -- /tmp/me.wav /tmp/them.wav
require "../src/llamero"

SAMPLE_RATE   = 16_000
CHUNK_SAMPLES = SAMPLE_RATE // 2 # 0.5s per push

# Minimal RIFF/WAVE reader: 16kHz mono Float32 or PCM16.
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

    abort "expected mono audio, got #{channels} channels" unless channels == 1
    abort "expected #{SAMPLE_RATE}Hz, got #{sample_rate}Hz" unless sample_rate == SAMPLE_RATE

    io = IO::Memory.new(data)
    case {audio_format, bits_per_sample}
    when {3_u16, 32_u16}
      Slice(Float32).new(data.size // 4) { io.read_bytes(Float32, IO::ByteFormat::LittleEndian) }
    when {1_u16, 16_u16}
      Slice(Float32).new(data.size // 2) { io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_f32 / 32_768.0_f32 }
    else
      abort "unsupported WAV encoding (format #{audio_format}, #{bits_per_sample}-bit)"
    end
  end
end

me_path = ARGV[0]?
them_path = ARGV[1]?
unless me_path && them_path
  abort "usage: crystal run examples/native_meeting_test.cr -- /path/to/me.wav /path/to/them.wav"
end
[me_path, them_path].each { |p| abort "not found: #{p}" unless File.exists?(p) }

bridge = Llamero::Native::AudioFFIBridge.try_load
abort "Audio bridge dylib not found. Build: cd native/llamero-audio && ./build.sh" unless bridge
puts "bridge: #{bridge.name} (#{bridge.library_path})"

me_samples = read_wav_samples(me_path)
them_samples = read_wav_samples(them_path)
puts "me:   #{(me_samples.size / SAMPLE_RATE.to_f).round(1)}s"
puts "them: #{(them_samples.size / SAMPLE_RATE.to_f).round(1)}s"

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)
audio.on_event do |event|
  case event
  when Llamero::Native::AsrModelLoadStartedEvent
    puts "loading streaming models (first run downloads)..."
  when Llamero::Native::AsrModelLoadedEvent
    puts "streaming models loaded in #{event.load_time_ms.round(0)}ms"
  end
end

journal = File.join(Dir.tempdir, "llamero-meeting-#{Time.utc.to_unix}.jsonl")
meeting = audio.start_meeting(journal: journal)
meeting.on_line do |line|
  stamp = line.end_ms.try { |ms| " [#{(ms / 1000).round(1)}s]" } || ""
  puts "  #{line.speaker}: #{line.text}#{stamp}"
end

puts "\nstreaming both channels (interleaved 0.5s chunks)..."
started = Time.instant
me_off = 0
them_off = 0
# Interleave the two capture streams the way concurrent callbacks would arrive.
while me_off < me_samples.size || them_off < them_samples.size
  if me_off < me_samples.size
    count = Math.min(CHUNK_SAMPLES, me_samples.size - me_off)
    meeting.push_me(me_samples[me_off, count]); me_off += count
  end
  if them_off < them_samples.size
    count = Math.min(CHUNK_SAMPLES, them_samples.size - them_off)
    meeting.push_them(them_samples[them_off, count]); them_off += count
  end
end

transcript = meeting.finish
elapsed = Time.instant - started

puts "\n=== merged transcript (#{transcript.size} lines) ==="
transcript.each do |line|
  stamp = line.start_ms.try { |ms| " @#{(ms / 1000).round(1)}s" } || ""
  puts "  #{line.speaker}:#{stamp} #{line.text}"
end
puts "\nwall time: #{elapsed.total_seconds.round(1)}s"
puts "journal (crash-safe, recoverable): #{journal}"
puts "  recovered: #{Llamero::Native::TranscriptJournal.read(journal).size} lines"
audio.close
