require "json"
require "./events"

module Llamero
  # Parses JSONL output from `claude -p --output-format stream-json
  # --include-partial-messages` into a stream of typed CliEvent values.
  #
  # Each #parse_line call returns 0..N events. Feed it stdout one line at a
  # time. Empty lines and JSON parse failures are silently skipped so a
  # single garbage frame cannot take down the run.
  class ClaudeStreamParser < CliStreamParser
    getter session_id : String? = nil

    def parse_line(line : String) : Array(CliEvent)
      stripped = line.strip
      return [] of CliEvent if stripped.empty?

      begin
        raw = JSON.parse(stripped)
      rescue JSON::ParseException
        return [] of CliEvent
      end

      events_from(raw)
    end

    private def events_from(raw : JSON::Any) : Array(CliEvent)
      frame_type = raw["type"]?.try(&.as_s?)
      case frame_type
      when "system"
        parse_system(raw)
      when "stream_event"
        parse_stream_event(raw)
      when "assistant"
        parse_assistant(raw)
      when "user"
        parse_user(raw)
      when "result"
        parse_result(raw)
      else
        [UnknownEvent.new(raw).as(CliEvent)]
      end
    end

    private def parse_system(raw) : Array(CliEvent)
      return [] of CliEvent unless raw["subtype"]?.try(&.as_s?) == "init"

      sid = pick_session_id(raw)
      return [] of CliEvent unless sid

      @session_id = sid
      model = raw["model"]?.try(&.as_s?)
      [SessionInitEvent.new(raw, sid, model).as(CliEvent)]
    end

    private def parse_stream_event(raw) : Array(CliEvent)
      event = raw["event"]?
      return [] of CliEvent unless event

      case event["type"]?.try(&.as_s?)
      when "message_start"
        msg_id = event.dig?("message", "id").try(&.as_s?)
        [MessageStartEvent.new(raw, msg_id).as(CliEvent)]
      when "content_block_delta"
        parse_content_block_delta(raw, event)
      else
        [] of CliEvent
      end
    end

    private def parse_content_block_delta(raw, event) : Array(CliEvent)
      delta = event["delta"]?
      return [] of CliEvent unless delta

      case delta["type"]?.try(&.as_s?)
      when "text_delta"
        text = delta["text"]?.try(&.as_s?) || ""
        [ContentDeltaEvent.new(raw, ContentDeltaEvent::Kind::Text, text).as(CliEvent)]
      when "thinking_delta"
        text = delta["thinking"]?.try(&.as_s?) || ""
        [ContentDeltaEvent.new(raw, ContentDeltaEvent::Kind::Thinking, text).as(CliEvent)]
      else
        [] of CliEvent
      end
    end

    private def parse_assistant(raw) : Array(CliEvent)
      if sid = pick_session_id(raw)
        @session_id ||= sid
      end

      events = [] of CliEvent
      content = raw.dig?("message", "content")
      return events unless content && content.as_a?

      content.as_a.each do |block|
        next unless block["type"]?.try(&.as_s?) == "tool_use"

        id = block["id"]?.try(&.as_s?)
        name = block["name"]?.try(&.as_s?)
        input = block["input"]? || JSON::Any.new({} of String => JSON::Any)
        next unless id && name

        events << ToolUseEvent.new(raw, id, name, input)
      end
      events
    end

    private def parse_user(raw) : Array(CliEvent)
      events = [] of CliEvent
      content = raw.dig?("message", "content")
      return events unless content && content.as_a?

      content.as_a.each do |block|
        next unless block["type"]?.try(&.as_s?) == "tool_result"

        id = block["tool_use_id"]?.try(&.as_s?)
        next unless id

        text = stringify_tool_result_content(block["content"]?)
        is_error = block["is_error"]?.try(&.as_bool?) || false
        events << ToolResultEvent.new(raw, id, text, is_error)
      end
      events
    end

    # Tool result content can be either a plain string or an array of
    # content blocks. Flatten both into a single string for downstream use.
    private def stringify_tool_result_content(content : JSON::Any?) : String
      return "" unless content

      if str = content.as_s?
        return str
      end

      if arr = content.as_a?
        return arr.compact_map { |b| b["text"]?.try(&.as_s?) }.join
      end

      content.to_s
    end

    private def parse_result(raw) : Array(CliEvent)
      stop_reason = raw["subtype"]?.try(&.as_s?)
      usage = parse_usage(raw["usage"]?)
      [MessageStopEvent.new(raw, stop_reason, usage).as(CliEvent)]
    end

    private def parse_usage(raw : JSON::Any?) : Usage
      return Usage.new unless raw

      Usage.new(
        input_tokens: raw["input_tokens"]?.try(&.as_i?) || 0,
        output_tokens: raw["output_tokens"]?.try(&.as_i?) || 0,
        cache_creation_input_tokens: raw["cache_creation_input_tokens"]?.try(&.as_i?) || 0,
        cache_read_input_tokens: raw["cache_read_input_tokens"]?.try(&.as_i?) || 0,
      )
    end

    # Session id can appear under several keys depending on the CLI
    # version and frame type; check all of them.
    private def pick_session_id(raw : JSON::Any) : String?
      {"session_id", "sessionId", "conversation_id", "conversationId"}.each do |key|
        if v = raw[key]?.try(&.as_s?)
          return v
        end
      end
      nil
    end
  end
end
