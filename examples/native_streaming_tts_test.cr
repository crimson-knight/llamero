# Streaming TTS smoke test: synthesize a multi-sentence reply with
# `speak_streaming`, which emits one PCM chunk per sentence as soon as it is
# ready. Measures time-to-first-audio (TTFA) — the whole point of streaming:
# the app can start playing sentence 1 while later sentences synthesize.
#
# Build the bridge first:  cd native/llamero-audio && ./build.sh
# Run:  crystal run examples/native_streaming_tts_test.cr
require "../src/llamero"

text = ARGV[0]? ||
       "I found three problems in that file. " \
       "The first is a missing import at the top. " \
       "The second is a type error on line forty. " \
       "And the third is an unhandled nil in the parser."

bridge = Llamero::Native::AudioFFIBridge.try_load
abort "Audio bridge dylib not found. Build: cd native/llamero-audio && ./build.sh" unless bridge
puts "bridge: #{bridge.name} (#{bridge.library_path})"

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)
audio.on_event do |event|
  case event
  when Llamero::Native::TtsModelLoadStartedEvent
    puts "loading Kokoro TTS (first run downloads)..."
  when Llamero::Native::TtsModelLoadedEvent
    puts "Kokoro loaded in #{event.load_time_ms.round(0)}ms"
  end
end

started = Time.instant
first_at : Time::Span? = nil
chunks = 0
samples = 0

spoken = audio.speak_streaming(text) do |chunk|
  now = Time.instant - started
  first_at ||= now
  chunks += 1
  samples += chunk.pcm.size // 2
  marker = chunk.final? ? " (final)" : ""
  puts "  chunk #{chunk.chunk_index}: #{chunk.pcm.size // 2} samples @ #{chunk.sample_rate}Hz, " \
       "#{chunk.duration_ms.round(0)}ms#{marker} — arrived #{now.total_milliseconds.round(0)}ms"
end

elapsed = Time.instant - started
ttfa = first_at.try(&.total_milliseconds) || 0.0
puts
puts "TTFA (time to first audio): #{ttfa.round(0)}ms"
puts "full synthesis: #{elapsed.total_milliseconds.round(0)}ms across #{chunks} chunks (#{samples} samples)"
if ttfa > 0
  puts "=> first audio is playable #{(elapsed.total_milliseconds / ttfa).round(1)}x sooner than waiting for the whole utterance"
end
puts "completed wav: #{spoken.try(&.path)}"
audio.close
