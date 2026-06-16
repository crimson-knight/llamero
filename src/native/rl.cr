require "json"

module Llamero::Native
  # A graded check on a generated completion: a name and a score in 0.0..1.0.
  # Rewards compose into a Rubric. Static-analysis rewards (format/compile) make
  # the signal objective and verifiable rather than a learned judge's guess.
  abstract class Reward
    abstract def name : String
    abstract def score(prompt : String, completion : String) : Float64
  end

  # Reward = `crystal tool format --check` reports NO CHANGES: the completion is
  # already perfectly formatted (which also requires it to parse). This is the
  # "knows the exact syntax and formatting" signal. `wrap` turns a completion
  # into a full source file when the completion is a fragment.
  class CrystalFormatReward < Reward
    def initialize(@wrap : String -> String = ->(c : String) { c })
    end

    def name : String
      "format-clean"
    end

    def score(prompt : String, completion : String) : Float64
      # `crystal tool format` always wants a single trailing newline; normalize
      # it so we judge the code's formatting, not a stripped trailing newline.
      text = @wrap.call(completion)
      text += "\n" unless text.ends_with?("\n")
      RL.crystal_ok?(["tool", "format", "--check", "-"], stdin: text) ? 1.0 : 0.0
    end
  end

  # Reward = `crystal build --no-codegen` reports NO ERRORS: the completion
  # type-checks (the compiler is the LSP backend). The "no errors" signal.
  class CrystalCompileReward < Reward
    def initialize(@wrap : String -> String = ->(c : String) { c })
    end

    def name : String
      "compiles"
    end

    def score(prompt : String, completion : String) : Float64
      ExampleGenerator.compiles?(@wrap.call(completion)) ? 1.0 : 0.0
    end
  end

  # Reward from an arbitrary proc — e.g. "the output is a single `record`",
  # schema validation, or a citation check.
  class FunctionReward < Reward
    def initialize(@name : String, @fn : (String, String) -> Float64)
    end

    def name : String
      @name
    end

    def score(prompt : String, completion : String) : Float64
      @fn.call(prompt, completion)
    end
  end

  # A weighted combination of rewards. `score` returns the weighted total plus a
  # per-reward breakdown so a practice loop can report exactly what improved.
  class Rubric
    getter items : Array({Reward, Float64})

    def initialize(@items : Array({Reward, Float64}))
      raise ArgumentError.new("Rubric needs at least one reward") if @items.empty?
    end

    def self.new(*rewards : Reward) : Rubric
      new(rewards.to_a.map { |r| {r.as(Reward), 1.0} })
    end

    def score(prompt : String, completion : String) : {Float64, Hash(String, Float64)}
      total_weight = @items.sum { |(_, w)| w }
      breakdown = {} of String => Float64
      weighted = 0.0
      @items.each do |(reward, weight)|
        s = reward.score(prompt, completion)
        breakdown[reward.name] = s
        weighted += s * weight
      end
      {weighted / total_weight, breakdown}
    end
  end

  module RL
    # Run a crystal subcommand with `stdin` piped in; true iff it exits 0.
    def self.crystal_ok?(args : Array(String), stdin : String) : Bool
      Process.run(
        "crystal", args,
        input: IO::Memory.new(stdin),
        output: Process::Redirect::Close,
        error: Process::Redirect::Close
      ).success?
    end

    # Pull a fenced code block out of a model completion, else return it stripped.
    def self.extract_code(text : String) : String
      cleaned = text.gsub(/<think>.*?<\/think>/m, "")
      if m = cleaned.match(/```(?:[a-zA-Z]*)\n(.*?)```/m)
        m[1].strip
      else
        cleaned.strip
      end
    end
  end

  # A reward-driven self-improvement cycle (expert iteration / rejection-sampling
  # RL) that runs on the existing SFT engine — no policy-gradient code needed:
  #
  #   1. PRACTICE — for each training prompt, sample several completions.
  #   2. JUDGE    — score each with the rubric (objective static-analysis checks).
  #   3. SELECT   — keep the best attempt per prompt when it clears `keep_threshold`.
  #   4. LEARN    — SFT the adapter on the accumulated best attempts.
  #   5. MEASURE  — score the model (greedy) on HELD-OUT prompts it never trains on.
  #
  # A rising held-out score across rounds is the validation that the cycle works:
  # the model practiced, was judged, and generalized the improvement to unseen
  # questions.
  class PracticeLoop
    # One round's outcome.
    record RoundResult,
      round : Int32,
      kept : Int32,
      train_best_mean : Float64,
      holdout_score : Float64,
      holdout_breakdown : Hash(String, Float64)

    def initialize(
      @session : ModelSession,
      @rubric : Rubric,
      @train_prompts : Array(String),
      @holdout_prompts : Array(String),
      @adapter_name : String,
      @system_prompt : String? = nil,
    )
    end

    # Greedy completion for `prompt` with the currently-resident model/adapter.
    private def answer(prompt : String, temperature : Float32?, max_tokens : Int32) : String
      messages = [] of Message
      messages << Message.system(@system_prompt.not_nil!) if @system_prompt
      messages << Message.user(prompt)
      RL.extract_code(@session.chat(messages, temperature: temperature, max_tokens: max_tokens).content)
    end

    # Mean rubric score (greedy) over a prompt set, plus the averaged breakdown.
    private def evaluate(prompts : Array(String), max_tokens : Int32) : {Float64, Hash(String, Float64)}
      totals = Hash(String, Float64).new(0.0)
      sum = 0.0
      prompts.each do |prompt|
        score, breakdown = @rubric.score(prompt, answer(prompt, nil, max_tokens))
        sum += score
        breakdown.each { |k, v| totals[k] += v }
      end
      n = prompts.size
      mean_breakdown = totals.transform_values { |v| (v / n).round(3) }
      {(sum / n).round(3), mean_breakdown}
    end

    # The held-out score before any training (the baseline to beat).
    getter baseline : {Float64, Hash(String, Float64)}? = nil

    def run(
      rounds : Int32 = 3,
      samples : Int32 = 6,
      temperature : Float32 = 0.8_f32,
      keep_threshold : Float64 = 1.0,
      max_tokens : Int32 = 160,
      seed : Array({String, String}) = [] of {String, String},
      train_config : AdapterTrainingConfig = default_config,
    ) : Array(RoundResult)
      stack = AdapterStack.additive([AdapterSlot.new(@adapter_name)])
      # Accumulated best (prompt, completion). An optional seed of known-good
      # examples (e.g. from ExampleGenerator) warms the buffer so the cycle has
      # something to learn from before the model's own attempts clear the bar.
      buffer = seed.dup
      results = [] of RoundResult

      @baseline = evaluate(@holdout_prompts, max_tokens)

      rounds.times do |r|
        # 1-3. Practice on the training prompts, keep the best per prompt.
        best_scores = [] of Float64
        @train_prompts.each do |prompt|
          best_completion = nil
          best_score = -1.0
          samples.times do
            completion = answer(prompt, temperature, max_tokens)
            score, _ = @rubric.score(prompt, completion)
            if score > best_score
              best_score = score
              best_completion = completion
            end
          end
          best_scores << best_score
          if (c = best_completion) && best_score >= keep_threshold && !c.blank?
            buffer << {prompt, c}
          end
        end

        # 4. Learn from the accumulated best attempts (fresh adapter each round).
        unique = buffer.to_h.to_a # dedupe by prompt, keep latest best
        if unique.size > 0
          @session.deactivate_adapters
          dataset = TrainingDataset.new(@system_prompt)
          unique.each { |prompt, completion| dataset.add(prompt, completion) }
          @session.train_adapter(@adapter_name, dataset, train_config)
          @session.activate_adapters(stack)
        end

        # 5. Measure generalization on the held-out prompts.
        holdout, breakdown = evaluate(@holdout_prompts, max_tokens)
        results << RoundResult.new(
          round: r,
          kept: unique.size,
          train_best_mean: (best_scores.sum / best_scores.size).round(3),
          holdout_score: holdout,
          holdout_breakdown: breakdown,
        )
      end

      results
    end

    private def default_config : AdapterTrainingConfig
      config = AdapterTrainingConfig.new
      config.iterations = 120
      config.num_layers = 8
      config.batch_size = 1
      config.learning_rate = 1e-4
      config
    end
  end
end
