# Real on-device vision inference through the Swift MLX bridge.
#
#   crystal-alpha run examples/native_vision_test.cr -- \
#     mlx-community/gemma-3-4b-it-qat-4bit@3d9ef289111449933c22761961f16a5df237ce2a \
#     /absolute/path/to/image.jpg [path|bytes|both]
require "../src/llamero"

DEFAULT_MODEL = "mlx-community/gemma-3-4b-it-qat-4bit@3d9ef289111449933c22761961f16a5df237ce2a"

model_id = ARGV[0]? || DEFAULT_MODEL
image_path = ARGV[1]? || abort(
  "usage: crystal-alpha run examples/native_vision_test.cr -- [model-id] <image.jpg> [path|bytes|both]"
)
mode = ARGV[2]? || "path"
abort "mode must be path, bytes, or both" unless mode.in?("path", "bytes", "both")
abort "image not found: #{image_path}" unless File.file?(image_path)

bridge = Llamero::Native::MLXBridge.try_load
unless bridge
  abort "MLX bridge dylib not found. Build it with: cd native/llamero-mlx && ./build.sh " \
        "(or set LLAMERO_MLX_LIB to the dylib path)"
end

puts "bridge: #{bridge.name} (#{bridge.library_path})"
puts "model: #{model_id}"
puts "image: #{Path[image_path].expand}"

runtime = Llamero::Native::MLXRuntime.new(model_id: model_id, bridge: bridge)
session = runtime.start_session

begin
  puts "loading model (the first run downloads it from Hugging Face)..."
  load = session.load_model
  puts "loaded in #{load.load_time_ms.round(0)}ms, " \
       "gpu memory #{(load.memory_bytes / (1024.0 * 1024.0)).round(1)}MB"

  prompt = "Describe this image. Name the dominant colored shape in one short sentence."

  if mode.in?("path", "both")
    puts "\n--- path vision ---"
    puts "PATH_ANSWER_BEGIN"
    response = session.generate_stream(prompt, image_path: image_path, max_tokens: 64) do |chunk|
      print chunk
      STDOUT.flush
    end
    puts "\nPATH_ANSWER_END"
    puts "#{response.metrics.output_tokens} tokens @ " \
         "#{response.metrics.tokens_per_second.round(1)} tok/s " \
         "(image+prompt #{response.metrics.time_to_first_token_ms.round(0)}ms, " \
         "total #{response.metrics.total_time_ms.round(0)}ms)"
  end

  if mode.in?("bytes", "both")
    puts "\n--- JPEG bytes vision ---"
    encoded_jpeg = File.read(image_path)
    encoded = encoded_jpeg.to_slice
    puts "BYTES_ANSWER_BEGIN"
    response = session.generate_stream(prompt, image_bytes: encoded, max_tokens: 64) do |chunk|
      print chunk
      STDOUT.flush
    end
    puts "\nBYTES_ANSWER_END"
    puts "#{response.metrics.output_tokens} tokens @ " \
         "#{response.metrics.tokens_per_second.round(1)} tok/s " \
         "(image+prompt #{response.metrics.time_to_first_token_ms.round(0)}ms, " \
         "total #{response.metrics.total_time_ms.round(0)}ms)"
  end
ensure
  runtime.close
end
