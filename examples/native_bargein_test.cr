# Barge-in smoke test: start a long streaming reply, then cancel it (as if the
# user started talking over the assistant). Confirms `cancel_speech` stops
# further synthesis and `speak_streaming` returns nil.
#
# Run:  crystal run examples/native_bargein_test.cr
require "../src/llamero"

# A long reply so synthesis is still in flight when we barge in.
text = (1..12).map { |i| "This is sentence number #{i} of a fairly long spoken reply." }.join(" ")

bridge = Llamero::Native::AudioFFIBridge.try_load
abort "Audio bridge dylib not found. Build: cd native/llamero-audio && ./build.sh" unless bridge
puts "bridge: #{bridge.name}"

audio = Llamero::Native::AudioRuntime.new(bridge: bridge)
chunks = 0
result = audio.speak_streaming(text) do |chunk|
  chunks += 1
  puts "  chunk #{chunk.chunk_index} arrived"
  # Barge-in: the user starts talking after the first sentence.
  if chunk.chunk_index == 0
    puts "  >> BARGE-IN: cancelling speech"
    audio.cancel_speech
  end
end

puts
puts "chunks produced before stop: #{chunks} (of 12 sentences)"
puts "result: #{result.nil? ? "nil (cancelled, as expected)" : "completed — barge-in did NOT stop it"}"
audio.close
