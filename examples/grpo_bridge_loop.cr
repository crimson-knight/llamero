# Part 2: the BRIDGE drives the whole GRPO loop. One call — session.grpo_train —
# and the bridge samples completions, asks Crystal for each reward via the
# reward-callback FFI (the rubric runs on the Crystal thread), computes
# group-relative advantages, and runs the KL-anchored weighted update for N
# rounds. Crystal only supplies the prompts and the reward function.
#
#   crystal run examples/grpo_bridge_loop.cr
require "../src/llamero"

MODEL = ARGV[0]? || "mlx-community/gemma-3-1b-it-4bit"

record Spec, name : String, fields : Array({String, String})

def instr(s : Spec) : String
  "Write a Crystal record named #{s.name} with fields #{s.fields.map { |n, t| "#{n} : #{t}" }.join(", ")}. Output only the record."
end

TRAIN = [
  Spec.new("Point", [{"x", "Int32"}, {"y", "Int32"}]),
  Spec.new("User", [{"name", "String"}, {"age", "Int32"}]),
  Spec.new("Color", [{"r", "Int32"}, {"g", "Int32"}, {"b", "Int32"}]),
  Spec.new("Money", [{"amount", "Float64"}, {"currency", "String"}]),
]
HOLDOUT = [
  Spec.new("Book", [{"title", "String"}, {"pages", "Int32"}]),
  Spec.new("Coord", [{"lat", "Float64"}, {"lng", "Float64"}]),
  Spec.new("Rect", [{"w", "Int32"}, {"h", "Int32"}]),
]

bridge = Llamero::Native::MLXBridge.try_load
abort "MLX bridge dylib not found" unless bridge
runtime = Llamero::Native::MLXRuntime.new(model_id: MODEL, bridge: bridge)
session = runtime.start_session
puts "loading #{MODEL} ..."
session.load_model

rubric = Llamero::Native::Rubric.new(
  Llamero::Native::CrystalCompileReward.new,
  Llamero::Native::CrystalFormatReward.new,
)

# The reward callback the BRIDGE invokes for every sampled completion.
reward_calls = 0
reward = ->(_prompt : String, completion : String) : Float64 do
  reward_calls += 1
  score, _ = rubric.score("", Llamero::Native::RL.extract_code(completion))
  score
end

holdout_score = ->do
  total = 0.0
  HOLDOUT.each do |s|
    gen = Llamero::Native::RL.extract_code(session.chat([Llamero::Message.user(instr(s))], max_tokens: 48).content)
    total += rubric.score("", gen)[0]
  end
  (total / HOLDOUT.size).round(3)
end

base = holdout_score.call
puts "baseline held-out rubric: #{base}"

config = Llamero::Native::AdapterTrainingConfig.new
config.iterations = (ENV["ITERS"]?.try(&.to_i?) || 60) # weighted-update steps per round
config.num_layers = 8
config.learning_rate = 5e-6
config.kl_beta = 0.05

rounds = (ENV["ROUNDS"]?.try(&.to_i?) || 2)
samples = (ENV["SAMPLES"]?.try(&.to_i?) || 6)
puts "bridge-driven GRPO: #{rounds} rounds x #{samples} samples (bridge generates + asks Crystal for rewards)"

# Surface the bridge's per-round mean reward through a session event listener.
round_log = [] of Float64
session.on_event do |event|
  if event.is_a?(Llamero::Native::UnknownNativeEvent) && event.raw["event"]?.try(&.as_s) == "grpo_round"
    mr = event.raw["mean_reward"]?.try(&.as_f) || 0.0
    round_log << mr
    puts "  round #{event.raw["round"]?} mean_reward=#{mr.round(3)} samples=#{event.raw["samples"]?}"
  end
end

descriptor = session.grpo_train(
  "grpo-bridge", TRAIN.map { |s| instr(s) }, reward,
  config: config, rounds: rounds, samples: samples, temperature: 0.9_f32, max_tokens: 48
)

session.activate_adapters(
  Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("grpo-bridge")])
)
after = holdout_score.call
runtime.close

puts "\n=== bridge-driven GRPO results ==="
puts "reward callback invoked #{reward_calls} times (from the bridge, via FFI)"
puts "per-round mean reward: #{round_log.map(&.round(3))}"
puts "held-out rubric: #{base} -> #{after}"
if reward_calls > 0 && after >= base
  puts "BRIDGE-DRIVEN GRPO VALIDATED — the bridge ran the loop, called back #{reward_calls}x for rewards; held-out #{base} -> #{after}"
else
  abort "BRIDGE-DRIVEN GRPO did not validate (reward_calls=#{reward_calls}, held-out #{base} -> #{after})"
end
