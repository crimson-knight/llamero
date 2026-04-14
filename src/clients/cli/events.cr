require "json"
require "../base_api_client"

module Llamero
  # Typed events produced by parsing an AI CLI's JSONL output stream.
  # Each concrete event corresponds to a recognized frame shape from the
  # underlying CLI (currently Claude Code). Unrecognized frames surface as
  # UnknownEvent so callers can log and keep going.
  abstract struct CliEvent
    getter raw : JSON::Any

    def initialize(@raw : JSON::Any)
    end
  end

  # First frame of a new run: captures the session id the CLI chose.
  # For `claude -p --session-id <uuid>` this will echo our supplied uuid;
  # without one supplied, the CLI mints a new uuid we must capture for resume.
  struct SessionInitEvent < CliEvent
    getter session_id : String
    getter model : String?

    def initialize(raw, @session_id : String, @model : String? = nil)
      super(raw)
    end
  end

  struct MessageStartEvent < CliEvent
    getter message_id : String?

    def initialize(raw, @message_id : String? = nil)
      super(raw)
    end
  end

  # An incremental chunk of assistant output. `kind` separates reasoning
  # (thinking) tokens from user-facing text.
  struct ContentDeltaEvent < CliEvent
    enum Kind
      Text
      Thinking
    end

    getter kind : Kind
    getter text : String

    def initialize(raw, @kind : Kind, @text : String)
      super(raw)
    end
  end

  struct ToolUseEvent < CliEvent
    getter tool_use_id : String
    getter name : String
    getter input : JSON::Any

    def initialize(raw, @tool_use_id : String, @name : String, @input : JSON::Any)
      super(raw)
    end
  end

  struct ToolResultEvent < CliEvent
    getter tool_use_id : String
    getter content : String
    getter is_error : Bool

    def initialize(raw, @tool_use_id : String, @content : String, @is_error : Bool = false)
      super(raw)
    end
  end

  struct MessageStopEvent < CliEvent
    getter stop_reason : String?
    getter usage : Usage

    def initialize(raw, @stop_reason : String? = nil, @usage : Usage = Usage.new)
      super(raw)
    end
  end

  # Frame the parser did not recognize. Surfaced so callers can log/trace
  # without crashing when Claude ships a new frame type.
  struct UnknownEvent < CliEvent
  end

  # Abstract protocol every per-CLI parser implements. Consumed by
  # CliClient so the supervisor/client layer stays CLI-agnostic.
  abstract class CliStreamParser
    abstract def parse_line(line : String) : Array(CliEvent)
    abstract def session_id : String?
  end
end
