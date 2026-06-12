# Real on-device speaker diarization smoke test. With no arguments, this
# creates a two-speaker WAV locally using macOS `say`, then runs Parakeet ASR
# plus FluidAudio's offline diarizer through the Swift bridge.
#
# Build the bridge first:
#   cd native/llamero-audio && ./build.sh
#
# Then run:
#   crystal run examples/native_diarization_test.cr
#
# Or pass your own meeting/voice file:
#   crystal run examples/native_diarization_test.cr -- /path/to/meeting.wav
require "../src/llamero"

SAMPLE_RATE = 16_000

def read_wav_samples(path : String) : Slice(Float32)
  File.open(path) do |file|
    abort "#{path} is not a RIFF file" unless file.read_string(4) == "RIFF"
    file.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
    abort "#{path} is not a WAVE file" unless file.read_string(4) == "WAVE"

    audio_format = 0_u16
    channels = 0_u16
    sample_rate = 0_u32
    bits_per_sample = 0_u16
    data = Bytes.empty

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
        data = Bytes.new(chunk_size)
        file.read_fully(data)
        break
      else
        file.skip(chunk_size)
      end
    end

    abort "expected mono audio, got #{channels} channels" unless channels == 1
    abort "expected #{SAMPLE_RATE}Hz audio, got #{sample_rate}Hz" unless sample_rate == SAMPLE_RATE

    io = IO::Memory.new(data)
    case {audio_format, bits_per_sample}
    when {3_u16, 32_u16}
      Slice(Float32).new(data.size // 4) { io.read_bytes(Float32, IO::ByteFormat::LittleEndian) }
    when {1_u16, 16_u16}
      Slice(Float32).new(data.size // 2) do
        io.read_bytes(Int16, IO::ByteFormat::LittleEndian).to_f32 / 32_768.0_f32
      end
    else
      abort "unsupported WAV encoding (format #{audio_format}, #{bits_per_sample}-bit)"
    end
  end
end

def write_float_wav(path : String, samples : Array(Float32)) : Nil
  data_size = samples.size * 4
  File.open(path, "w") do |file|
    file << "RIFF"
    file.write_bytes((36 + data_size).to_u32, IO::ByteFormat::LittleEndian)
    file << "WAVE"
    file << "fmt "
    file.write_bytes(16_u32, IO::ByteFormat::LittleEndian)
    file.write_bytes(3_u16, IO::ByteFormat::LittleEndian) # IEEE Float32
    file.write_bytes(1_u16, IO::ByteFormat::LittleEndian)
    file.write_bytes(SAMPLE_RATE.to_u32, IO::ByteFormat::LittleEndian)
    file.write_bytes((SAMPLE_RATE * 4).to_u32, IO::ByteFormat::LittleEndian)
    file.write_bytes(4_u16, IO::ByteFormat::LittleEndian)
    file.write_bytes(32_u16, IO::ByteFormat::LittleEndian)
    file << "data"
    file.write_bytes(data_size.to_u32, IO::ByteFormat::LittleEndian)
    samples.each { |sample| file.write_bytes(sample, IO::ByteFormat::LittleEndian) }
  end
end

def available_say_voices : Array(String)
  output = IO::Memory.new
  status = Process.run("say", ["-v", "?"], output: output, error: Process::Redirect::Close)
  return [] of String unless status.success?
  output.to_s.lines.compact_map do |line|
    line.match(/^\S+/).try(&.[0])
  end
end

def pick_voice(voices : Array(String), preferred : Array(String), used : Array(String) = [] of String) : String
  preferred.each do |candidate|
    return candidate if voices.includes?(candidate) && !used.includes?(candidate)
  end
  if fallback = voices.find { |voice| !used.includes?(voice) }
    return fallback
  end
  abort "macOS say has fewer than two installed voices"
end

def run_say(voice : String, text : String, output_path : String) : Nil
  status = Process.run(
    "say",
    ["-v", voice, "-o", output_path, "--data-format=LEF32@16000", text],
    output: Process::Redirect::Inherit,
    error: Process::Redirect::Inherit
  )
  abort "say failed for voice #{voice}" unless status.success?
end

def generate_two_speaker_wav : String
  voices = available_say_voices
  voice_a = pick_voice(voices, ["Samantha", "Alex", "Victoria"])
  voice_b = pick_voice(voices, ["Daniel", "Fred", "Karen", "Moira"], [voice_a])

  dir = File.join(Dir.tempdir, "llamero-diarization-#{Time.utc.to_unix_ms}")
  Dir.mkdir_p(dir)
  part_a = File.join(dir, "speaker-a.wav")
  part_b = File.join(dir, "speaker-b.wav")
  output = File.join(dir, "two-speaker-meeting.wav")

  run_say(voice_a,
    "Good morning. I will review the launch plan and summarize the first issue. " \
    "The dashboard is working and the audio bridge is ready.",
    part_a)
  run_say(voice_b,
    "Thanks. I will cover the next action items and confirm the owners. " \
    "We should verify the timeline before the meeting ends.",
    part_b)

  silence = Array(Float32).new(SAMPLE_RATE * 2, 0.0_f32)
  samples = [] of Float32
  samples.concat(read_wav_samples(part_a).to_a)
  samples.concat(silence)
  samples.concat(read_wav_samples(part_b).to_a)
  samples.concat(silence)
  write_float_wav(output, samples)

  puts "generated test audio: #{output}"
  puts "speaker A voice: #{voice_a}, speaker B voice: #{voice_b}"
  output
end

provided_path = ARGV[0]?
audio_path = if provided_path
               abort "audio file not found: #{provided_path}" unless File.exists?(provided_path)
               provided_path
             else
               generate_two_speaker_wav
             end

bridge = Llamero::Native::AudioFFIBridge.try_load
unless bridge
  abort "Audio bridge dylib not found. Build it with: cd native/llamero-audio && ./build.sh " \
        "(or set LLAMERO_AUDIO_LIB to the dylib path)"
end

puts "bridge: #{bridge.name} (#{bridge.library_path})"

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)
audio.on_event do |event|
  case event
  when Llamero::Native::AsrModelLoadStartedEvent
    puts "loading Parakeet #{event.model_version}..."
  when Llamero::Native::AsrModelLoadProgressEvent
    print "\rasr model download/load: #{(event.progress * 100).round(1)}%   "
    STDOUT.flush
  when Llamero::Native::AsrModelLoadedEvent
    puts "\nasr models loaded in #{event.load_time_ms.round(0)}ms"
  when Llamero::Native::DiarizerModelLoadStartedEvent
    puts "loading offline diarizer models..."
  when Llamero::Native::DiarizerModelLoadProgressEvent
    print "\rdiarizer model download/load: #{(event.progress * 100).round(1)}%   "
    STDOUT.flush
  when Llamero::Native::DiarizerModelLoadedEvent
    puts "\ndiarizer models loaded in #{event.load_time_ms.round(0)}ms"
  end
end

puts "\n--- diarized transcription #{audio_path} ---"
result = if provided_path
           audio.transcribe_diarized(audio_path)
         else
           audio.transcribe_diarized(audio_path, speaker_count: 2)
         end

puts "transcript: #{result.text}"
puts "audio #{(result.duration_ms / 1000).round(2)}s processed in " \
     "#{(result.processing_time_ms / 1000).round(2)}s " \
     "(asr #{(result.asr_processing_time_ms / 1000).round(2)}s, " \
     "diarizer #{(result.diarization_processing_time_ms / 1000).round(2)}s)"

puts "\nspeaker-attributed segments:"
result.segments.each do |segment|
  puts "  #{segment.speaker} #{(segment.start_ms / 1000).round(2)}s-" \
       "#{(segment.end_ms / 1000).round(2)}s: #{segment.text}"
end

puts "\nraw speaker windows:"
result.speaker_segments.each do |segment|
  puts "  #{segment.speaker} #{(segment.start_ms / 1000).round(2)}s-" \
       "#{(segment.end_ms / 1000).round(2)}s"
end

audio.close
