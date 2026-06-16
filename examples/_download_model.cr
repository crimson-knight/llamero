require "../src/llamero"
m = ARGV[0]? || "mlx-community/gemma-3-4b-it-4bit"
dl = Llamero::Native::ModelDownloader.new
if dl.cached?(m)
  puts "READY (cached): #{dl.model_dir(m)}"
else
  puts "downloading #{m} ..."
  path = dl.resolve(m) { |pct| print "\r#{(pct * 100).round(1)}%   "; STDOUT.flush }
  puts "\nREADY: #{path}"
end
