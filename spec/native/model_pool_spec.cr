require "../spec_helper"
require "file_utils"

private def with_adapter_dir(&)
  dir = File.join(Dir.tempdir, "llamero-pool-adapter-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  File.write(File.join(dir, "adapters.safetensors"), "fake-lora-weights")
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Llamero::Native::ModelPool do
  describe "registration and lookup" do
    it "registers named members and lists them in order" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
      pool.add("specialist", model_id: "model-a")
      pool.add("chat", model_id: "model-b")

      pool.names.should eq(["specialist", "chat"])
      pool.size.should eq(2)
    end

    it "raises a clear error for unknown names" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
      pool.add("chat", model_id: "model-b")

      error = expect_raises(Llamero::Native::PoolMemberNotFoundError, /No model named "specialist"/) do
        pool["specialist"]
      end
      error.member_name.should eq("specialist")
      error.message.should_not be_nil
      error.message.not_nil!.should contain("chat")
    end

    it "rejects duplicate and blank member names" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
      pool.add("chat", model_id: "model-b")

      expect_raises(ArgumentError, /already has a member/) do
        pool.add("chat", model_id: "model-c")
      end
      expect_raises(ArgumentError, /blank/) do
        pool.add("", model_id: "model-c")
      end
    end

    it "fails at add time when the default stack names an unregistered adapter" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)

      expect_raises(Llamero::Native::AdapterNotFoundError, /unregistered adapter "ghost"/) do
        pool.add("specialist",
          model_id: "model-a",
          default_stack: Llamero::Native::AdapterStack.additive([
            Llamero::Native::AdapterSlot.new("ghost"),
          ])
        )
      end
    end
  end

  describe "lazy loading" do
    it "does not load a model until the member is first used" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
      pool.add("specialist", model_id: "model-a")
      pool.add("chat", model_id: "model-b")

      pool.loaded_names.should be_empty
      pool.total_memory_bytes.should eq(0)

      pool.chat("chat", [Llamero::Message.user("hi")])

      pool.loaded_names.should eq(["chat"])
      pool["chat"].load_count.should eq(1)
    end

    it "loads each member exactly once across repeated access" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
      pool.add("chat", model_id: "model-b")

      first = pool["chat"]
      3.times { pool.chat("chat", [Llamero::Message.user("hi")]) }

      pool["chat"].should be(first)
      pool["chat"].load_count.should eq(1)
    end
  end

  describe "adapter handling" do
    it "auto-activates the member's default adapter stack on first load" do
      with_adapter_dir do |dir|
        pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
        pool.add("specialist",
          model_id: "model-a",
          adapters: [{"domain", dir}],
          default_stack: Llamero::Native::AdapterStack.additive([
            Llamero::Native::AdapterSlot.new("domain"),
          ])
        )

        response = pool.chat("specialist", [Llamero::Message.user("hi")])

        response.content.should contain("with adapters domain")
        pool["specialist"].active_adapter_stack.slots.map(&.name).should eq(["domain"])
        # Activation must not have reloaded the base model.
        pool["specialist"].load_count.should eq(1)
        pool["specialist"].base_model_reloaded?.should be_false
      end
    end

    it "keeps adapter stacks independent between members" do
      with_adapter_dir do |dir|
        pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
        pool.add("specialist",
          model_id: "model-a",
          adapters: [{"domain", dir}],
          default_stack: Llamero::Native::AdapterStack.additive([
            Llamero::Native::AdapterSlot.new("domain"),
          ])
        )
        pool.add("chat", model_id: "model-b")

        pool.chat("specialist", [Llamero::Message.user("hi")]).content.should contain("with adapters domain")
        pool.chat("chat", [Llamero::Message.user("hi")]).content.should eq("mock response from model-b")
        pool["chat"].active_adapter_stack.empty?.should be_true
      end
    end
  end

  describe "routing" do
    it "delegates structured output to the member session" do
      bridge = Llamero::Native::MockBridge.new
      bridge.scripted_responses << %({"name": "Ada", "age": 36})
      pool = Llamero::Native::ModelPool.new(bridge: bridge)
      pool.add("specialist", model_id: "model-a")

      response = pool.chat_structured("specialist", [Llamero::Message.user("Who?")], TestPersonGrammar)

      person = response.parsed.not_nil!
      person.name.should eq("Ada")
      person.age.should eq(36)
      response.model_id.should eq("model-a")
    end
  end

  describe "memory accounting" do
    it "sums load metrics across loaded members only" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
      pool.add("specialist", model_id: "model-a")
      pool.add("chat", model_id: "model-b")

      pool.total_memory_bytes.should eq(0)

      pool["specialist"]
      pool.total_memory_bytes.should eq(Llamero::Native::MockBridge::MEMORY_BYTES)

      pool["chat"]
      pool.total_memory_bytes.should eq(2 * Llamero::Native::MockBridge::MEMORY_BYTES)
    end
  end

  describe "lifecycle" do
    it "closes every member and is idempotent" do
      pool = Llamero::Native::ModelPool.new(bridge: Llamero::Native::MockBridge.new)
      pool.add("specialist", model_id: "model-a")
      pool.add("chat", model_id: "model-b")
      specialist = pool["specialist"]

      pool.close
      pool.close # idempotent

      pool.closed?.should be_true
      specialist.closed?.should be_true

      expect_raises(Llamero::Native::SessionStateError, /closed/) do
        pool["specialist"]
      end
      expect_raises(Llamero::Native::SessionStateError, /closed/) do
        pool.add("late", model_id: "model-c")
      end
    end
  end
end
