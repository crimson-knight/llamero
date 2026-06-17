require "../spec_helper"

module Llamero::Native
  describe ErrorRepair do
    good = "require \"json\"\n\nclass Counter\n  def initialize\n    @n = 0\n  end\n\n  def bump : Int32\n    @n += 1\n  end\nend\n"

    it "drop_last_end removes the final end" do
      ErrorRepair.drop_last_end(good).not_nil!.count("end").should be < good.count("end")
      ErrorRepair.drop_last_end("x = 1\n").should be_nil
    end

    it "swap_return_type changes an explicit return type to a different one" do
      m = ErrorRepair.swap_return_type(good).not_nil!
      m.should_not contain(": Int32")
      m.should match(/def bump\s*:\s*\w+/)
    end

    it "typo_method_call mangles a method call name" do
      ErrorRepair.typo_method_call("puts items.size\n").not_nil!.should contain(".siz")
      ErrorRepair.typo_method_call("x = 1\n").should be_nil
    end

    it "drop_require removes a require line" do
      ErrorRepair.drop_require(good).not_nil!.should_not contain("require")
      ErrorRepair.drop_require("class X\nend\n").should be_nil
    end

    it "to_training_pair embeds the error + broken code in the prompt, fix as completion" do
      pair = ErrorRepair::RepairPair.new(broken: "class X", error: "Error: oops", fixed: "class X\nend", mutation: "drop-end")
      prompt, completion = ErrorRepair.to_training_pair(pair)
      prompt.should contain("Error: oops")
      prompt.should contain("class X")
      completion.should eq("class X\nend")
    end
  end
end
