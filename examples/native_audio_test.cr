# Audio track smoke test: real on-device speech-to-text (Parakeet) and
# text-to-speech (Kokoro) through the Swift FluidAudio bridge.
#
# Build the bridge first:
#   cd native/llamero-audio && ./build.sh
#
# Then run with a speech recording (first run downloads the CoreML models
# from Hugging Face):
#   crystal run examples/native_audio_test.cr -- /path/to/speech.wav
#
# Verifies the audio-track Phase 1 claims:
#   1. Parakeet transcribes a file with word-level timestamps, faster than
#      real time.
#   2. Kokoro speaks the transcript back to a playable WAV.
require "../src/llamero"

audio_path = ARGV[0]?
unless audio_path
  abort "usage: crystal run examples/native_audio_test.cr -- /path/to/speech.wav"
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

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)

audio.on_event do |event|
  case event
  when Llamero::Native::AsrModelLoadStartedEvent
    puts "loading Parakeet #{event.model_version} (first run downloads from HuggingFace)..."
  when Llamero::Native::AsrModelLoadProgressEvent
    print "\rasr model download/load: #{(event.progress * 100).round(1)}%   "
    STDOUT.flush
  when Llamero::Native::AsrModelLoadedEvent
    puts "\nasr models loaded in #{event.load_time_ms.round(0)}ms"
  when Llamero::Native::TtsModelLoadStartedEvent
    puts "loading Kokoro TTS (first run downloads from HuggingFace)..."
  when Llamero::Native::TtsModelLoadedEvent
    puts "tts models loaded in #{event.load_time_ms.round(0)}ms"
  end
end

puts "\n--- transcribing #{audio_path} ---"
result = audio.transcribe(audio_path)

puts "transcript: #{result.text}"
puts "audio #{(result.duration_ms / 1000).round(2)}s transcribed in " \
     "#{(result.processing_time_ms / 1000).round(2)}s " \
     "(#{(result.duration_ms / result.processing_time_ms).round(1)}x real time, " \
     "confidence #{(result.confidence * 100).round(1)}%)"

unless result.segments.empty?
  puts "first words:"
  result.segments.first(5).each do |segment|
    puts "  #{segment.start_ms.round(0)}ms-#{segment.end_ms.round(0)}ms  #{segment.text}"
  end
end

if result.text.blank?
  abort "nothing transcribed; not speaking an empty transcript back"
end

puts "\n--- speaking the transcript back ---"
spoken = audio.speak(result.text)

puts "spoke #{(spoken.duration_ms / 1000).round(2)}s of audio in " \
     "#{(spoken.synthesis_time_ms / 1000).round(2)}s (#{spoken.sample_rate}Hz)"
puts "output: #{spoken.path}"
puts "play it with: afplay #{spoken.path}"

audio.close
puts "\naudio smoke test complete"
