require "../spec_helper"

describe Llamero::Native::MLXRuntime do
  it "instantiates against a mock bridge with the documented configuration" do
    runtime = Llamero::Native::MLXRuntime.new(
      model_id: "mlx-community/Qwen3-0.6B-4bit",
      fallback_model_id: "mlx-community/SmolLM-135M-Instruct-4bit",
      cache_limit_bytes: 64 * 1024 * 1024,
      bridge: Llamero::Native::MockBridge.new
    )

    runtime.model_id.should eq("mlx-community/Qwen3-0.6B-4bit")
    runtime.fallback_model_id.should eq("mlx-community/SmolLM-135M-Instruct-4bit")
    runtime.cache_limit_bytes.should eq(64_i64 * 1024 * 1024)
    runtime.bridge_name.should eq("mock")
    runtime.real_bridge?.should be_false
  end

  it "rejects blank model ids" do
    expect_raises(ArgumentError, /blank/) do
      Llamero::Native::MLXRuntime.new(model_id: "", bridge: Llamero::Native::MockBridge.new)
    end
  end

  it "hands out sessions bound to the runtime model" do
    runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: Llamero::Native::MockBridge.new)
    session = runtime.start_session

    session.model_id.should eq("test-model")
    session.state.unloaded?.should be_true
  end

  it "closes all sessions when the runtime closes" do
    runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: Llamero::Native::MockBridge.new)
    first = runtime.start_session
    second = runtime.start_session
    first.load_model

    runtime.close

    runtime.closed?.should be_true
    first.closed?.should be_true
    second.closed?.should be_true

    expect_raises(Llamero::Native::SessionStateError, /closed/) do
      runtime.start_session
    end
  end

  it "shares one adapter registry across sessions" do
    runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: Llamero::Native::MockBridge.new)
    runtime.adapters.should be(runtime.adapters)
    runtime.adapters.size.should eq(0)
  end
end
