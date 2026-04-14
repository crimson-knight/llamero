require "spec"
require "../../../src/clients/cli/claude_stream_parser"

private def fixture_lines(name : String) : Array(String)
  path = File.expand_path("../../../fixtures/cli/#{name}", __FILE__)
  File.read(path).lines.map(&.chomp).reject(&.empty?)
end

private def parse_all(parser : Llamero::ClaudeStreamParser, lines : Array(String)) : Array(Llamero::CliEvent)
  events = [] of Llamero::CliEvent
  lines.each { |line| events.concat(parser.parse_line(line)) }
  events
end

describe Llamero::ClaudeStreamParser do
  describe "#parse_line" do
    it "captures session_id from the system init frame" do
      parser = Llamero::ClaudeStreamParser.new
      events = parse_all(parser, fixture_lines("claude_simple_run.jsonl"))

      parser.session_id.should eq("11111111-1111-1111-1111-111111111111")
      events.first.should be_a(Llamero::SessionInitEvent)
      init = events.first.as(Llamero::SessionInitEvent)
      init.session_id.should eq("11111111-1111-1111-1111-111111111111")
      init.model.should eq("claude-sonnet-4-20250514")
    end

    it "emits text deltas for content_block_delta.text_delta frames" do
      parser = Llamero::ClaudeStreamParser.new
      events = parse_all(parser, fixture_lines("claude_simple_run.jsonl"))

      deltas = events.select(Llamero::ContentDeltaEvent).select(&.kind.text?)
      deltas.map(&.text).should eq(["Hello", ", world!"])
    end

    it "emits a MessageStopEvent with usage including cache tokens" do
      parser = Llamero::ClaudeStreamParser.new
      events = parse_all(parser, fixture_lines("claude_simple_run.jsonl"))

      stops = events.select(Llamero::MessageStopEvent)
      stops.size.should eq(1)
      usage = stops.first.usage
      usage.input_tokens.should eq(12)
      usage.output_tokens.should eq(5)
      usage.cache_read_input_tokens.should eq(100)
    end

    it "emits a MessageStartEvent with the assistant message id" do
      parser = Llamero::ClaudeStreamParser.new
      events = parse_all(parser, fixture_lines("claude_simple_run.jsonl"))

      starts = events.select(Llamero::MessageStartEvent)
      starts.size.should eq(1)
      starts.first.message_id.should eq("msg_abc")
    end

    it "emits ToolUseEvent from assistant content blocks" do
      parser = Llamero::ClaudeStreamParser.new
      events = parse_all(parser, fixture_lines("claude_tool_use.jsonl"))

      tool_uses = events.select(Llamero::ToolUseEvent)
      tool_uses.size.should eq(1)
      tool_uses.first.tool_use_id.should eq("toolu_01")
      tool_uses.first.name.should eq("Read")
      tool_uses.first.input["path"].as_s.should eq("/tmp/foo.txt")
    end

    it "emits ToolResultEvent from user content blocks" do
      parser = Llamero::ClaudeStreamParser.new
      events = parse_all(parser, fixture_lines("claude_tool_use.jsonl"))

      results = events.select(Llamero::ToolResultEvent)
      results.size.should eq(1)
      results.first.tool_use_id.should eq("toolu_01")
      results.first.content.should eq("file contents here")
      results.first.is_error.should be_false
    end

    it "distinguishes thinking deltas from text deltas" do
      parser = Llamero::ClaudeStreamParser.new
      events = parse_all(parser, fixture_lines("claude_tool_use.jsonl"))

      thinking = events.select(Llamero::ContentDeltaEvent).select(&.kind.thinking?)
      thinking.map(&.text).should eq(["I should read the file."])
    end

    it "skips empty lines and malformed JSON without raising" do
      parser = Llamero::ClaudeStreamParser.new
      parser.parse_line("").should be_empty
      parser.parse_line("   ").should be_empty
      parser.parse_line("not json at all").should be_empty
      parser.parse_line(%({"unterminated": )).should be_empty
    end

    it "surfaces unrecognized frame types as UnknownEvent" do
      parser = Llamero::ClaudeStreamParser.new
      events = parser.parse_line(%({"type":"something_new","data":42}))
      events.size.should eq(1)
      events.first.should be_a(Llamero::UnknownEvent)
    end
  end
end
