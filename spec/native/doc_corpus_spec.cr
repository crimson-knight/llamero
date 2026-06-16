require "../spec_helper"

# A minimal slice of the `crystal docs --format=json` shape: program -> types,
# each type/member carrying a raw-markdown `doc` with fenced code blocks.
private DOCS_JSON = <<-JSON
{"program":{"full_name":"Top Level Namespace","kind":"module","types":[
  {"full_name":"Greeter","kind":"class","doc":"A greeter that says hello.\\n\\n```\\nGreeter.new(\\"x\\").greet\\n```",
   "instance_methods":[
     {"name":"greet","args_string":"() : String","doc":"Returns a greeting.\\n\\n```crystal\\ng.greet # => \\"hi\\"\\n```"}
   ],
   "types":[]}
]}}
JSON

describe Llamero::Native::DocExtractor do
  it "extracts code blocks and their signature context from crystal docs JSON" do
    ex = Llamero::Native::DocExtractor.from_docs_json(DOCS_JSON)
    ex.examples.size.should eq(2)

    codes = ex.examples.map(&.code)
    codes.should contain(%(Greeter.new("x").greet))
    codes.should contain(%(g.greet # => "hi"))

    # The method example is tagged with its signature.
    method_ex = ex.examples.find! { |e| e.code.includes?("g.greet") }
    method_ex.context.should contain("Greeter#greet() : String")
    method_ex.context.should contain("Returns a greeting")
    method_ex.language.should eq("crystal")
  end

  it "builds supervised and unsupervised datasets from extracted examples" do
    ex = Llamero::Native::DocExtractor.from_docs_json(DOCS_JSON)
    sft = ex.to_supervised_dataset
    sft.size.should eq(2)
    sft.raw_text?.should be_false

    unsup = ex.to_unsupervised_dataset
    unsup.raw_text?.should be_true
    unsup.size.should eq(2)
  end

  it "extracts code blocks from a standalone markdown page with heading context" do
    md = <<-MD
    # Controllers

    A basic controller looks like:

    ```crystal
    class UsersController < ApplicationController
      def index; end
    end
    ```
    MD
    dir = File.join(Dir.tempdir, "doccorpus-#{Random::Secure.hex(4)}")
    begin
      FileUtils.mkdir_p(dir)
      path = File.join(dir, "guide.md")
      File.write(path, md)
      ex = Llamero::Native::DocExtractor.from_markdown([path])
      ex.examples.size.should eq(1)
      ex.examples.first.code.should contain("class UsersController")
      ex.examples.first.context.should contain("Controllers")
    ensure
      FileUtils.rm_rf(dir)
    end
  end
end

describe Llamero::Native::ExampleGenerator do
  it "mixes and matches chunks into every valid combination" do
    gen = Llamero::Native::ExampleGenerator.new("class {{name}}\n{{body}}\nend")
    gen.slot("name", ["A", "B"])
    gen.combo("body", ["x", "y"], min: 1) # subsets {x},{y},{x,y} => 3

    examples = gen.to_a
    examples.size.should eq(6) # 2 names * 3 body subsets
    examples.should contain("class A\nx\nend")
    examples.should contain("class B\nx\n\ny\nend")
    examples.none?(&.includes?("{{")).should be_true # all slots filled
  end

  it "prunes combinations that fail a constraint" do
    gen = Llamero::Native::ExampleGenerator.new("{{a}}{{b}}")
    gen.slot("a", ["1", "2"])
    gen.slot("b", ["x", "y"])
    gen.constrain { |sel| !(sel["a"] == "2" && sel["b"] == "y") }
    gen.to_a.size.should eq(3) # 4 minus the rejected (2,y)
  end

  it "compile-verifies generated programs" do
    Llamero::Native::ExampleGenerator.compiles?("puts(1 + 1)").should be_true
    Llamero::Native::ExampleGenerator.compiles?("puts(1 +)").should be_false
  end
end
