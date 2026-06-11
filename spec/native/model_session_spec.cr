require "../spec_helper"
require "file_utils"

private def build_runtime(bridge : Llamero::Native::MockBridge = Llamero::Native::MockBridge.new)
  Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: bridge)
end

private def with_registered_adapter(runtime : Llamero::Native::MLXRuntime, name : String, &)
  dir = File.join(Dir.tempdir, "llamero-adapter-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "adapters.safetensors"), "fake-lora-weights")
  runtime.adapters.register(name, dir)
  yield
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Llamero::Native::ModelSession do
  describe "state transitions" do
    it "starts unloaded and transitions to loaded" do
      session = build_runtime.start_session
      session.state.unloaded?.should be_true
      session.loaded?.should be_false

      metrics = session.load_model

      session.state.loaded?.should be_true
      metrics.load_time_ms.should eq(Llamero::Native::MockBridge::LOAD_TIME_MS)
      metrics.memory_bytes.should eq(Llamero::Native::MockBridge::MEMORY_BYTES)
      metrics.reloaded.should be_false
    end

    it "refuses to chat before the model is loaded" do
      session = build_runtime.start_session

      expect_raises(Llamero::Native::SessionStateError, /not loaded/) do
        session.chat([Llamero::Message.user("hi")])
      end
    end

    it "marks the session failed when the model load fails" do
      bridge = Llamero::Native::MockBridge.new
      bridge.fail_next_model_load = true
      session = build_runtime(bridge).start_session

      expect_raises(Llamero::Native::ModelLoadError, /Mock model load failure/) do
        session.load_model
      end
      session.state.failed?.should be_true

      # The failure knob resets, so a retry succeeds without a new session.
      session.load_model
      session.loaded?.should be_true
    end

    it "refuses all operations after close" do
      session = build_runtime.start_session
      session.load_model
      session.close

      session.closed?.should be_true
      expect_raises(Llamero::Native::SessionStateError, /closed/) do
        session.load_model
      end
    end
  end

  describe "resident model invariant" do
    it "does not reload the base model across repeated chats" do
      session = build_runtime.start_session
      session.load_model

      3.times { session.chat([Llamero::Message.user("hello")]) }

      session.load_count.should eq(1)
    end

    it "does not reload the base model when adapters change" do
      runtime = build_runtime
      session = runtime.start_session
      session.load_model

      with_registered_adapter(runtime, "sql") do
        stack = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("sql", scale: 0.8)])

        session.activate_adapters(stack)
        session.chat([Llamero::Message.user("query time")])
        session.deactivate_adapters
        session.chat([Llamero::Message.user("base again")])

        session.load_count.should eq(1)
        session.base_model_reloaded?.should be_false
      end
    end
  end

  describe "adapter activation" do
    it "tracks the active adapter stack and exposes it in responses" do
      runtime = build_runtime
      session = runtime.start_session
      session.load_model

      with_registered_adapter(runtime, "sql") do
        stack = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("sql")])
        session.activate_adapters(stack)

        session.active_adapter_stack.slots.map(&.name).should eq(["sql"])

        response = session.chat([Llamero::Message.user("hi")])
        response.adapter_stack.slots.map(&.name).should eq(["sql"])
        response.content.should contain("adapters sql")

        session.deactivate_adapters
        session.active_adapter_stack.empty?.should be_true
      end
    end

    it "fails fast for unregistered adapters without touching the bridge" do
      session = build_runtime.start_session
      session.load_model

      stack = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("ghost")])
      expect_raises(Llamero::Native::AdapterNotFoundError) do
        session.activate_adapters(stack)
      end

      session.active_adapter_stack.empty?.should be_true
      session.loaded?.should be_true
    end

    it "surfaces bridge activation errors without killing the session" do
      bridge = Llamero::Native::MockBridge.new
      runtime = build_runtime(bridge)
      session = runtime.start_session
      session.load_model

      with_registered_adapter(runtime, "sql") do
        bridge.fail_next_adapter_activation = true
        stack = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("sql")])

        error = expect_raises(Llamero::Native::AdapterActivationError) do
          session.activate_adapters(stack)
        end
        error.base_model_loaded.should be_true

        # Session stays usable on the base model.
        session.loaded?.should be_true
        session.active_adapter_stack.empty?.should be_true
        session.chat([Llamero::Message.user("still alive?")]).content.should contain("mock response")
      end
    end
  end

  describe "chat and streaming" do
    it "returns content with generation metrics" do
      session = build_runtime.start_session
      session.load_model

      response = session.chat([Llamero::Message.user("one two three")])

      response.content.should eq("mock response from test-model")
      response.model_id.should eq("test-model")
      response.session_id.should_not be_empty
      response.metrics.tokens_per_second.should eq(Llamero::Native::MockBridge::TOKENS_PER_SEC)
      response.metrics.input_tokens.should eq(3)
      response.metrics.output_tokens.should be > 0
      session.last_generation_metrics.should_not be_nil
    end

    it "streams deltas that concatenate to the full content" do
      session = build_runtime.start_session
      session.load_model

      chunks = [] of String
      response = session.chat_stream([Llamero::Message.user("hi")]) do |chunk|
        chunks << chunk
      end

      chunks.size.should be > 1
      chunks.join.should eq(response.content)
    end

    it "raises GenerationError but keeps the model resident on failure" do
      bridge = Llamero::Native::MockBridge.new
      session = build_runtime(bridge).start_session
      session.load_model

      bridge.fail_next_generation = true
      error = expect_raises(Llamero::Native::GenerationError) do
        session.chat([Llamero::Message.user("boom")])
      end

      error.base_model_loaded.should be_true
      session.loaded?.should be_true
      session.load_count.should eq(1)
    end

    it "fans typed events out to listeners" do
      session = build_runtime.start_session
      events = [] of Llamero::Native::NativeEvent
      session.on_event { |event| events << event }

      session.load_model
      session.chat([Llamero::Message.user("hi")])

      events.any?(Llamero::Native::ModelLoadedEvent).should be_true
      events.any?(Llamero::Native::TokenDeltaEvent).should be_true
      events.any?(Llamero::Native::GenerationCompletedEvent).should be_true
    end
  end

  describe "structured output" do
    it "parses scripted JSON into the schema class" do
      bridge = Llamero::Native::MockBridge.new
      bridge.scripted_responses << %({"name": "Ada", "age": 36})
      session = build_runtime(bridge).start_session
      session.load_model

      response = session.chat_structured([Llamero::Message.user("Who?")], TestPersonGrammar)

      person = response.parsed.not_nil!
      person.name.should eq("Ada")
      person.age.should eq(36)
      response.metrics.output_tokens.should be > 0
    end

    it "extracts JSON wrapped in code fences or prose" do
      bridge = Llamero::Native::MockBridge.new
      bridge.scripted_responses << "Sure! Here you go:\n```json\n{\"name\": \"Grace\", \"age\": 45}\n```"
      session = build_runtime(bridge).start_session
      session.load_model

      response = session.chat_structured([Llamero::Message.user("Who?")], TestPersonGrammar)
      response.parsed.not_nil!.name.should eq("Grace")
    end

    it "raises StructuredParseError with raw text, schema name, and adapter stack" do
      bridge = Llamero::Native::MockBridge.new
      bridge.scripted_responses << "definitely not json"
      session = build_runtime(bridge).start_session
      session.load_model

      error = expect_raises(Llamero::Native::StructuredParseError) do
        session.chat_structured([Llamero::Message.user("Who?")], TestPersonGrammar)
      end

      error.raw_text.should eq("definitely not json")
      error.schema_name.should eq("TestPersonGrammar")
      error.recoverable.should be_true
      error.base_model_loaded.should be_true

      # Retry runs without reloading the base model.
      bridge.scripted_responses << %({"name": "Ada", "age": 36})
      session.chat_structured([Llamero::Message.user("Who?")], TestPersonGrammar)
      session.load_count.should eq(1)
    end
  end
end
