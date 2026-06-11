require "../spec_helper"

describe Llamero::Message do
  describe ".system" do
    it "creates a system message" do
      message = Llamero::Message.system("You are a helpful assistant")

      message.role.should eq(Llamero::MessageRole::System)
      message.content.should eq("You are a helpful assistant")
    end
  end

  describe ".user" do
    it "creates a user message" do
      message = Llamero::Message.user("Hello!")

      message.role.should eq(Llamero::MessageRole::User)
      message.content.should eq("Hello!")
    end
  end

  describe ".assistant" do
    it "creates an assistant message" do
      message = Llamero::Message.assistant("Hi there!")

      message.role.should eq(Llamero::MessageRole::Assistant)
      message.content.should eq("Hi there!")
    end
  end

  describe ".tool" do
    it "creates a tool message" do
      message = Llamero::Message.tool("result", "call_123", "my_function")

      message.role.should eq(Llamero::MessageRole::Tool)
      message.content.should eq("result")
      message.tool_call_id.should eq("call_123")
      message.name.should eq("my_function")
    end
  end

  describe "JSON serialization" do
    it "serializes to JSON" do
      message = Llamero::Message.user("Hello")
      json = message.to_json

      json.should contain("\"role\"")
      json.should contain("\"content\":\"Hello\"")
    end

    it "deserializes from JSON" do
      json = %q({"role":"user","content":"Test"})
      message = Llamero::Message.from_json(json)

      message.role.should eq(Llamero::MessageRole::User)
      message.content.should eq("Test")
    end
  end
end

describe Llamero::Usage do
  describe "#initialize" do
    it "creates with default values" do
      usage = Llamero::Usage.new
      usage.input_tokens.should eq(0)
      usage.output_tokens.should eq(0)
    end

    it "creates with specified values" do
      usage = Llamero::Usage.new(input_tokens: 100, output_tokens: 50)
      usage.input_tokens.should eq(100)
      usage.output_tokens.should eq(50)
    end
  end

  describe "#total_tokens" do
    it "returns sum of input and output tokens" do
      usage = Llamero::Usage.new(input_tokens: 100, output_tokens: 50)
      usage.total_tokens.should eq(150)
    end
  end
end

describe Llamero::ChatResponse do
  describe "#initialize" do
    it "creates with required fields" do
      response = Llamero::ChatResponse(Nil).new(
        content: "Hello!",
        model: "gpt-4o"
      )

      response.content.should eq("Hello!")
      response.model.should eq("gpt-4o")
      response.finish_reason.should eq("stop")
      response.provider_used.should eq(:unknown)
      response.attempts.should eq(1)
    end

    it "creates with all fields" do
      usage = Llamero::Usage.new(input_tokens: 10, output_tokens: 20)
      response = Llamero::ChatResponse(Nil).new(
        content: "Test",
        model: "claude-3-opus",
        usage: usage,
        finish_reason: "end_turn",
        provider_used: :anthropic,
        attempts: 3
      )

      response.usage.total_tokens.should eq(30)
      response.finish_reason.should eq("end_turn")
      response.provider_used.should eq(:anthropic)
      response.attempts.should eq(3)
    end
  end

  describe "with parsed response" do
    it "stores parsed grammar" do
      grammar = TestPersonGrammar.new
      grammar.name = "Alice"
      grammar.age = 30

      response = Llamero::ChatResponse(TestPersonGrammar).new(
        content: %q({"name":"Alice","age":30}),
        model: "gpt-4o",
        parsed: grammar
      )

      response.parsed.should_not be_nil
      response.parsed.not_nil!.name.should eq("Alice")
      response.parsed.not_nil!.age.should eq(30)
    end
  end
end

describe Llamero::Feature do
  it "has expected feature values" do
    Llamero::Feature::StructuredOutput.should be_a(Llamero::Feature)
    Llamero::Feature::ToolCalling.should be_a(Llamero::Feature)
    Llamero::Feature::Streaming.should be_a(Llamero::Feature)
    Llamero::Feature::Embeddings.should be_a(Llamero::Feature)
    Llamero::Feature::Vision.should be_a(Llamero::Feature)
  end
end
