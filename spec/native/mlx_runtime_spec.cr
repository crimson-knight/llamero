require "../spec_helper"
require "file_utils"

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

  describe "multi-runtime coexistence" do
    it "keeps sessions on different runtimes independent on a shared bridge" do
      bridge = Llamero::Native::MockBridge.new
      specialist = Llamero::Native::MLXRuntime.new(model_id: "model-a", bridge: bridge)
      chat = Llamero::Native::MLXRuntime.new(model_id: "model-b", bridge: bridge)

      session_a = specialist.start_session
      session_b = chat.start_session
      session_a.load_model
      session_b.load_model

      # Bridge handles never collide: each session has a distinct identity.
      session_a.session_id.should_not eq(session_b.session_id)

      # Each session answers as its own model, with its own metrics.
      session_a.chat([Llamero::Message.user("hi")]).content.should eq("mock response from model-a")
      session_b.chat([Llamero::Message.user("hi")]).content.should eq("mock response from model-b")
      session_a.chat([Llamero::Message.user("again")])
      session_a.load_count.should eq(1)
      session_b.load_count.should eq(1)
    end

    it "keeps adapter state isolated between runtimes" do
      bridge = Llamero::Native::MockBridge.new
      specialist = Llamero::Native::MLXRuntime.new(model_id: "model-a", bridge: bridge)
      chat = Llamero::Native::MLXRuntime.new(model_id: "model-b", bridge: bridge)

      session_a = specialist.start_session
      session_b = chat.start_session
      session_a.load_model
      session_b.load_model

      dir = File.join(Dir.tempdir, "llamero-adapter-#{Random::Secure.hex(6)}")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "adapters.safetensors"), "fake-lora-weights")
      begin
        specialist.adapters.register("domain", dir)
        session_a.activate_adapters(
          Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("domain")])
        )

        session_a.chat([Llamero::Message.user("hi")]).content.should contain("with adapters domain")
        session_b.chat([Llamero::Message.user("hi")]).content.should eq("mock response from model-b")
        session_b.active_adapter_stack.empty?.should be_true

        # The other runtime's registry never learned about the adapter.
        chat.adapters.registered?("domain").should be_false
        session_a.load_count.should eq(1)
        session_b.load_count.should eq(1)
      ensure
        FileUtils.rm_rf(dir)
      end
    end

    it "closing one runtime does not disturb another" do
      bridge = Llamero::Native::MockBridge.new
      specialist = Llamero::Native::MLXRuntime.new(model_id: "model-a", bridge: bridge)
      chat = Llamero::Native::MLXRuntime.new(model_id: "model-b", bridge: bridge)

      session_a = specialist.start_session
      session_b = chat.start_session
      session_a.load_model
      session_b.load_model

      specialist.close

      specialist.closed?.should be_true
      session_a.closed?.should be_true
      chat.closed?.should be_false
      session_b.loaded?.should be_true
      session_b.chat([Llamero::Message.user("still here?")]).content.should eq("mock response from model-b")
      session_b.load_count.should eq(1)

      chat.close
      chat.closed?.should be_true
    end
  end
end
