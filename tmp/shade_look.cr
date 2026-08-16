require "../src/llamero"

image_path = ARGV[0]? || abort "usage: shade_look.cr <image.jpg>"
bridge = Llamero::Native::MLXBridge.try_load || abort "no MLX bridge"
runtime = Llamero::Native::MLXRuntime.new(model_id: "mlx-community/gemma-3-4b-it-qat-4bit", bridge: bridge)
session = runtime.start_session
session.load_model

prompt = <<-P
You are Shade, Seth's AI assistant — a composed, dryly witty gothic butler. This image is what your webcam sees right now. In TWO short sentences: (1) tell Seth what you observe about him and the room, naturally, as if greeting him; (2) ask him ONE specific, natural question about something you can actually see. Speak directly to Seth. No preamble, no markdown.
P

text = String.build do |sb|
  session.generate_stream(prompt, image_path: Path[image_path], max_tokens: 120) { |t| sb << t; print t }
end
puts
File.write("/tmp/shade_says.txt", text.strip)
