require "../spec_helper"
require "file_utils"

private def with_adapter_dir(weights : Bool = true, &)
  dir = File.join(Dir.tempdir, "llamero-adapter-#{Random::Secure.hex(6)}")
  Dir.mkdir_p(dir)
  if weights
    File.write(File.join(dir, "adapters.safetensors"), "fake-lora-weights")
    File.write(File.join(dir, "adapter_config.json"), %({"num_layers": 4, "lora_parameters": {"rank": 8, "scale": 20.0}}))
  end
  yield dir
ensure
  FileUtils.rm_rf(dir) if dir
end

describe Llamero::Native::AdapterRegistry do
  it "registers a valid adapter directory and computes a checksum" do
    with_adapter_dir do |dir|
      registry = Llamero::Native::AdapterRegistry.new
      descriptor = registry.register("sql", dir)

      descriptor.name.should eq("sql")
      descriptor.path.should eq(Path[dir].expand.to_s)
      descriptor.checksum.size.should eq(16)
      registry.registered?("sql").should be_true
      registry.names.should eq(["sql"])
    end
  end

  it "computes the same checksum for the same artifact" do
    with_adapter_dir do |dir|
      first = Llamero::Native::AdapterRegistry.new.register("sql", dir)
      second = Llamero::Native::AdapterRegistry.new.register("renamed", dir)

      first.checksum.should eq(second.checksum)
    end
  end

  it "rejects directories that do not exist" do
    registry = Llamero::Native::AdapterRegistry.new

    expect_raises(Llamero::Native::AdapterNotFoundError, /does not exist/) do
      registry.register("ghost", "/nonexistent/llamero/adapter")
    end
  end

  it "rejects directories without safetensors weights" do
    with_adapter_dir(weights: false) do |dir|
      registry = Llamero::Native::AdapterRegistry.new

      expect_raises(Llamero::Native::AdapterActivationError, /no .safetensors/) do
        registry.register("empty", dir)
      end
    end
  end

  it "raises AdapterNotFoundError when looking up unregistered names" do
    registry = Llamero::Native::AdapterRegistry.new

    error = expect_raises(Llamero::Native::AdapterNotFoundError, /not registered/) do
      registry.lookup("missing")
    end
    error.adapter_name.should eq("missing")
    error.recoverable.should be_true
  end

  it "resolves every slot in a stack to its descriptor" do
    with_adapter_dir do |dir|
      registry = Llamero::Native::AdapterRegistry.new
      registry.register("sql", dir)
      registry.register("tone", dir)

      stack = Llamero::Native::AdapterStack.additive([
        Llamero::Native::AdapterSlot.new("sql"),
        Llamero::Native::AdapterSlot.new("tone", scale: 0.5),
      ])

      resolved = registry.resolve(stack)
      resolved.size.should eq(2)
      resolved[0][1].name.should eq("sql")
      resolved[1][0].scale.should eq(0.5)
    end
  end

  it "fails stack resolution fast for unregistered adapters" do
    registry = Llamero::Native::AdapterRegistry.new
    stack = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("missing")])

    expect_raises(Llamero::Native::AdapterNotFoundError) do
      registry.resolve(stack)
    end
  end
end
