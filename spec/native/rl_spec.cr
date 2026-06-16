require "../spec_helper"
require "file_utils"

private alias N = Llamero::Native

describe N::CrystalCompileReward do
  it "scores valid code 1.0 and invalid code 0.0" do
    r = N::CrystalCompileReward.new
    r.name.should eq("compiles")
    r.score("", "puts(1 + 1)").should eq(1.0)
    r.score("", "puts(1 +)").should eq(0.0)
  end
end

describe N::CrystalFormatReward do
  it "scores already-formatted 1.0 and messy 0.0" do
    r = N::CrystalFormatReward.new
    r.name.should eq("format-clean")
    r.score("", "puts(1 + 1)\n").should eq(1.0)
    r.score("", "puts( 1+1 )").should eq(0.0)
    # A canonical record with no trailing newline is still format-clean: the
    # reward normalizes the trailing newline so it judges code, not whitespace.
    r.score("", "record P, x : Int32").should eq(1.0)
  end
end

describe N::FunctionReward do
  it "delegates scoring to its proc" do
    r = N::FunctionReward.new("len", ->(_p : String, c : String) { c.size > 3 ? 1.0 : 0.0 })
    r.score("", "long").should eq(1.0)
    r.score("", "x").should eq(0.0)
  end
end

describe N::Rubric do
  it "combines rewards as a weighted mean with a per-reward breakdown" do
    a = N::FunctionReward.new("a", ->(_p : String, _c : String) { 1.0 }).as(N::Reward)
    b = N::FunctionReward.new("b", ->(_p : String, _c : String) { 0.0 }).as(N::Reward)
    rubric = N::Rubric.new([{a, 3.0}, {b, 1.0}])
    total, breakdown = rubric.score("p", "c")
    total.should eq(0.75) # (1*3 + 0*1) / 4
    breakdown["a"].should eq(1.0)
    breakdown["b"].should eq(0.0)
  end
end

describe N::RL do
  it "extracts fenced code, else returns the stripped text" do
    N::RL.extract_code("Here:\n```crystal\nrecord P, x : Int32\n```\ndone").should eq("record P, x : Int32")
    N::RL.extract_code("  record Q, y : Int32  ").should eq("record Q, y : Int32")
  end
end

describe N::PracticeLoop do
  it "runs the practice/judge/learn/measure cycle end-to-end (mock bridge)" do
    original = Llamero.storage_root
    tmp = File.join(Dir.tempdir, "llamero-rl-#{Random::Secure.hex(6)}")
    begin
      Llamero.storage_root = tmp
      runtime = N::MLXRuntime.new(model_id: "test-model", bridge: N::MockBridge.new)
      session = runtime.start_session
      session.load_model

      # Always-accept rubric so the buffer fills and a training round runs.
      rubric = N::Rubric.new(N::FunctionReward.new("ok", ->(_p : String, _c : String) { 1.0 }))
      practice = N::PracticeLoop.new(
        session: session, rubric: rubric,
        train_prompts: ["p1", "p2"], holdout_prompts: ["h1"],
        adapter_name: "rl-test"
      )
      results = practice.run(rounds: 2, samples: 2, max_tokens: 16)

      results.size.should eq(2)
      practice.baseline.should_not be_nil
      results.first.kept.should be > 0
      results.last.holdout_score.should eq(1.0) # always-1 rubric
      runtime.close
    ensure
      Llamero.storage_root = original
      FileUtils.rm_rf(tmp)
    end
  end
end

describe "ModelSession#grpo_train (bridge-driven loop)" do
  it "runs the bridge GRPO loop, invoking the reward callback and registering the adapter" do
    original = Llamero.storage_root
    tmp = File.join(Dir.tempdir, "llamero-grpo-#{Random::Secure.hex(6)}")
    begin
      Llamero.storage_root = tmp
      runtime = N::MLXRuntime.new(model_id: "test-model", bridge: N::MockBridge.new)
      session = runtime.start_session
      session.load_model

      reward_calls = 0
      reward = ->(_prompt : String, completion : String) : Float64 do
        reward_calls += 1
        completion.includes?("record") ? 1.0 : 0.0
      end

      descriptor = session.grpo_train("grpo-mock", ["write a record"], reward, rounds: 2, samples: 3)

      reward_calls.should eq(6) # 1 prompt * 3 samples * 2 rounds, all via the callback
      descriptor.name.should eq("grpo-mock")
      session.load_count.should eq(1) # GRPO did not reload the base
      runtime.close
    ensure
      Llamero.storage_root = original
      FileUtils.rm_rf(tmp)
    end
  end
end
