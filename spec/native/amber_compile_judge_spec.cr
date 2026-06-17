require "../spec_helper"

module Llamero::Native
  describe AmberCompileJudge do
    judge = AmberCompileJudge.new(amber_root: "/nonexistent/amber")

    describe "#domain_stubs" do
      it "stubs undefined top-level domain constants, not framework or own classes" do
        code = <<-CR
        class Order < Grant::Base
          column total : Int64
          belongs_to customer : Customer
          property line_items : Array(LineItem)
        end
        CR
        stubs = judge.domain_stubs(code)
        stubs.should contain("Customer")
        stubs.should contain("LineItem")
        stubs.should_not contain("Order")   # defined here
        stubs.should_not contain("Grant")   # framework
        stubs.should_not contain("Array")   # stdlib
        stubs.should_not contain("Int64")   # stdlib
      end

      it "takes the head of a qualified constant path (never a path segment)" do
        judge.domain_stubs("x = Amber::Controller::Base").should be_empty
        judge.domain_stubs("y = MyApp::Thing.new").should eq(["MyApp"])
      end
    end

    describe "#available?" do
      it "is false when the amber root is missing" do
        judge.available?.should be_false
      end

      it "compile? returns false (never raises) without a real amber root" do
        judge.compile?("class X < Amber::Controller::Base\nend").should be_false
      end
    end

    describe ".from_env" do
      it "is nil when AMBER_REPO is unset/missing" do
        AmberCompileJudge.from_env.should be_nil if ENV["AMBER_REPO"]?.nil?
      end
    end
  end
end
