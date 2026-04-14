require "spec"
require "../../../src/clients/cli/claude_cli_client"

# Test-only subclass that replaces the `claude` binary with `cat`ting a
# recorded JSONL fixture. This lets us exercise the full chat() flow
# (process + parser + client) without requiring claude on PATH.
private class FixtureClaudeClient < Llamero::ClaudeCliClient
  def initialize(@fixture_path : String)
    super()
  end

  def command : String
    "cat"
  end

  def base_args : Array(String)
    [@fixture_path]
  end

  def resume_args(session_id : String) : Array(String)
    [@fixture_path]
  end

  def model_arg(model : String) : Array(String)
    [] of String
  end

  def system_prompt_arg(prompt : String) : Array(String)
    [] of String
  end

  # No --session-id flag — `cat` doesn't understand it.
  protected def fresh_args : Array(String)
    base_args
  end
end

private def fixture(name : String) : String
  File.expand_path("../../../fixtures/cli/#{name}", __FILE__)
end

describe Llamero::ClaudeCliClient do
  describe "#chat end-to-end" do
    it "returns the assistant text concatenated across deltas" do
      client = FixtureClaudeClient.new(fixture("claude_simple_run.jsonl"))
      response = client.chat([Llamero::Message.user("hi")])

      response.content.should eq("Hello, world!")
    end

    it "captures the session id for resume" do
      client = FixtureClaudeClient.new(fixture("claude_simple_run.jsonl"))
      client.chat([Llamero::Message.user("hi")])

      client.last_session_id.should eq("11111111-1111-1111-1111-111111111111")
    end

    it "populates Usage from the final result frame" do
      client = FixtureClaudeClient.new(fixture("claude_simple_run.jsonl"))
      response = client.chat([Llamero::Message.user("hi")])

      response.usage.input_tokens.should eq(12)
      response.usage.output_tokens.should eq(5)
      response.usage.cache_read_input_tokens.should eq(100)
    end

    it "collects all parser events for inspection" do
      client = FixtureClaudeClient.new(fixture("claude_tool_use.jsonl"))
      client.chat([Llamero::Message.user("hi")])

      client.last_events.any?(Llamero::ToolUseEvent).should be_true
      client.last_events.any?(Llamero::ToolResultEvent).should be_true
    end
  end

  describe "#chat_stream" do
    it "yields each text delta to the block in order" do
      client = FixtureClaudeClient.new(fixture("claude_simple_run.jsonl"))
      chunks = [] of String
      client.chat_stream([Llamero::Message.user("hi")]) { |chunk| chunks << chunk }

      chunks.should eq(["Hello", ", world!"])
    end
  end

  describe "ENV_SCRUB_LIST" do
    it "includes the credential and telemetry keys the CLI honors" do
      list = Llamero::ClaudeCliClient::ENV_SCRUB_LIST
      list.should contain("ANTHROPIC_API_KEY")
      list.should contain("CLAUDE_CODE_OAUTH_TOKEN")
      list.should contain("CLAUDE_CONFIG_DIR")
      list.should contain("OTEL_EXPORTER_OTLP_ENDPOINT")
    end
  end
end
