require "../../src/llamero"

lib ReproPlayer
  fun start = repro_player_start(path : LibC::Char*) : Void*
  fun playing = repro_player_is_playing(player : Void*) : Int32
  fun current_time = repro_player_current_time(player : Void*) : Float64
  fun duration = repro_player_duration(player : Void*) : Float64
  fun stop = repro_player_stop(player : Void*) : Void
end

def assert_playing(label : String, path : String) : Bool
  player = ReproPlayer.start(path.to_unsafe)
  raise "player failed to start for #{path}" if player.null?
  puts "PLAYBACK #{label} start isPlaying=#{ReproPlayer.playing(player)} " \
       "duration=#{ReproPlayer.duration(player).round(3)}"
  sleep 300.milliseconds
  playing = ReproPlayer.playing(player) == 1
  position = ReproPlayer.current_time(player)
  passed = playing && position >= 0.15
  puts "#{passed ? "PASS" : "FAIL"} playback-#{label} after_ms=300 " \
       "isPlaying=#{playing} currentTime=#{position.round(3)}"
  ReproPlayer.stop(player)
  passed
end

probe = ARGV[0]? || abort("usage: crystal_repro /path/to/probe.wav")
abort "probe file not found: #{probe}" unless File.exists?(probe)
output = File.join(Dir.tempdir, "llamero-playback-repro", "crystal.wav")
Dir.mkdir_p(File.dirname(output))

puts "MODE crystal pid=#{Process.pid}"
before = assert_playing("before", probe)

runtime : Llamero::Native::AudioRuntime? = nil
if ENV["REPRO_ISOLATED"]? == "1"
  result = Channel(String).new
  worker = Fiber::ExecutionContext::Isolated.new("crystal-repro-tts") do
    begin
      bridge = Llamero::Native::AudioFFIBridge.try_load
      raise "bridge unavailable" unless bridge
      puts "BRIDGE #{bridge.library_path} isolated=true"
      rt = Llamero::Native::AudioRuntime.new(bridge: bridge, tts_voice: "af_heart")
      spoken = rt.speak(
        "The isolated Crystal playback probe is running.",
        voice: "af_heart",
        output_path: output
      )
      runtime = rt
      result.send("SYNTH crystal duration_ms=#{spoken.duration_ms.round(0)} path=#{spoken.path}")
    rescue ex
      result.send("ERROR #{ex.message}")
    end
  end
  synthesis_result = result.receive
  abort synthesis_result if synthesis_result.starts_with?("ERROR ")
  puts synthesis_result
else
  bridge = Llamero::Native::AudioFFIBridge.try_load
  abort "bridge unavailable" unless bridge
  puts "BRIDGE #{bridge.library_path} isolated=false"
  rt = Llamero::Native::AudioRuntime.new(bridge: bridge, tts_voice: "af_heart")
  spoken = rt.speak(
    "The Crystal process playback probe is running.",
    voice: "af_heart",
    output_path: output
  )
  runtime = rt
  puts "SYNTH crystal duration_ms=#{spoken.duration_ms.round(0)} path=#{spoken.path}"
end

after_probe = assert_playing("after-probe", probe)
after_synthesis = assert_playing("after-synthesis", output)
runtime.try(&.close)
puts "RESULT crystal before=#{before ? "PASS" : "FAIL"} " \
     "afterProbe=#{after_probe ? "PASS" : "FAIL"} " \
     "afterSynthesis=#{after_synthesis ? "PASS" : "FAIL"}"
exit 1 unless before && after_probe && after_synthesis
