require "../spec_helper"

describe Llamero::Native::AdapterSlot do
  it "defaults scale to 1.0" do
    slot = Llamero::Native::AdapterSlot.new("sql")
    slot.scale.should eq(1.0)
  end

  it "rejects blank names" do
    expect_raises(ArgumentError, /blank/) do
      Llamero::Native::AdapterSlot.new("")
    end
  end

  it "rejects non-finite scales" do
    expect_raises(ArgumentError, /finite/) do
      Llamero::Native::AdapterSlot.new("sql", scale: Float64::INFINITY)
    end
    expect_raises(ArgumentError, /finite/) do
      Llamero::Native::AdapterSlot.new("sql", scale: Float64::NAN)
    end
  end
end

describe Llamero::Native::AdapterStack do
  it "builds an additive stack by default" do
    stack = Llamero::Native::AdapterStack.additive([
      Llamero::Native::AdapterSlot.new("sql", scale: 0.8),
      Llamero::Native::AdapterSlot.new("tone", scale: 0.4),
    ])

    stack.mode.additive?.should be_true
    stack.slots.size.should eq(2)
    stack.empty?.should be_false
  end

  it "treats an empty stack as base model only" do
    stack = Llamero::Native::AdapterStack.none
    stack.empty?.should be_true
    stack.stack_id.should eq("base")
  end

  it "rejects duplicate adapter names within a stack" do
    expect_raises(ArgumentError, /unique/) do
      Llamero::Native::AdapterStack.additive([
        Llamero::Native::AdapterSlot.new("sql"),
        Llamero::Native::AdapterSlot.new("sql", scale: 0.5),
      ])
    end
  end

  it "requires an explicit experimental flag for sequential mode" do
    slots = [Llamero::Native::AdapterSlot.new("sql")]

    expect_raises(ArgumentError, /experimental/) do
      Llamero::Native::AdapterStack.sequential(slots)
    end

    stack = Llamero::Native::AdapterStack.sequential(slots, experimental: true)
    stack.mode.sequential?.should be_true
  end

  it "derives a stable stack_id from contents" do
    build = -> {
      Llamero::Native::AdapterStack.additive([
        Llamero::Native::AdapterSlot.new("sql", scale: 0.8),
        Llamero::Native::AdapterSlot.new("tone", scale: 0.4),
      ])
    }

    build.call.stack_id.should eq(build.call.stack_id)
  end

  it "changes stack_id when slots or scales change" do
    base = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("sql", scale: 0.8)])
    rescaled = Llamero::Native::AdapterStack.additive([Llamero::Native::AdapterSlot.new("sql", scale: 0.5)])

    base.stack_id.should_not eq(rescaled.stack_id)
  end
end
