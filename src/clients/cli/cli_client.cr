require "uuid"
require "../base_api_client"
require "./events"
require "./cli_process"

module Llamero
  # Abstract base for clients that drive an external AI CLI as a subprocess
  # (Claude Code, Codex CLI, etc.) instead of talking to an HTTP API.
  #
  # Subclasses declare:
  # - `command` — the executable name (e.g. "claude")
  # - `base_args` — flags for a fresh run (stdout format, permissions, …)
  # - `resume_args(session_id)` — flags to continue an existing session
  # - `model_arg(model)` / `system_prompt_arg(prompt)` — flag builders
  # - `scrub_env_vars` — env keys to strip before spawning the child
  # - `new_parser` — a fresh per-run CliStreamParser
  #
  # The abstract class wires those into CliProcess + the stream parser so
  # chat/chat_stream become concrete.
  abstract class CliClient < APIClient
    # Captured after each run so the caller can resume by passing session_id
    # back on the next chat() call.
    getter last_session_id : String? = nil

    # Accumulates events from the most recent run — useful for tests and for
    # the upcoming typed-conversation graph. Cleared at the start of each run.
    getter last_events : Array(CliEvent) = [] of CliEvent

    def initialize(
      base_url : String? = nil,
      default_model : String? = nil,
      timeout : Time::Span = 10.minutes
    )
      super(api_key: "cli-no-auth", base_url: base_url, default_model: default_model, timeout: timeout)
    end

    # CLI binaries manage their own credentials; the APIClient key check
    # does not apply.
    protected def validate_credentials! : Nil
    end

    protected def get_default_api_key : String
      "cli-no-auth"
    end

    protected def get_default_base_url : String
      ""
    end

    protected def add_auth_headers(headers : HTTP::Headers) : Nil
    end

    abstract def command : String
    abstract def base_args : Array(String)
    abstract def resume_args(session_id : String) : Array(String)
    abstract def model_arg(model : String) : Array(String)
    abstract def system_prompt_arg(prompt : String) : Array(String)
    abstract def scrub_env_vars : Array(String)
    abstract def new_parser : CliStreamParser

    # Drive one CLI run to completion, return the concatenated assistant text.
    #
    # `session_id:` — if provided, resumes that session. Otherwise the CLI
    # receives a freshly minted UUID via --session-id (or equivalent).
    def chat(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
      session_id : String? = nil
    ) : ChatResponse(Nil)
      text_io = IO::Memory.new
      parser = new_parser
      usage = Usage.new
      stop_reason : String? = nil

      run_cli(messages, model, session_id, parser) do |event|
        case event
        when ContentDeltaEvent
          text_io << event.text if event.kind.text?
        when MessageStopEvent
          usage = event.usage
          stop_reason = event.stop_reason
        end
      end

      @last_session_id = parser.session_id

      ChatResponse(Nil).new(
        content: text_io.to_s,
        model: model || @default_model,
        usage: usage,
        finish_reason: stop_reason || "stop",
      )
    end

    def chat_stream(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
      session_id : String? = nil,
      &block : String -> Nil
    ) : Nil
      parser = new_parser

      run_cli(messages, model, session_id, parser) do |event|
        if event.is_a?(ContentDeltaEvent) && event.kind.text?
          block.call(event.text)
        end
      end

      @last_session_id = parser.session_id
    end

    def supports?(feature : Feature) : Bool
      case feature
      when .streaming?         then true
      when .tool_calling?      then true
      when .structured_output? then false # exposed via tool_use for now
      when .embeddings?        then false
      when .vision?            then true
      else false
      end
    end

    private def run_cli(
      messages : Array(Message),
      model : String?,
      session_id : String?,
      parser : CliStreamParser,
      & : CliEvent -> Nil
    ) : Nil
      @last_events = [] of CliEvent

      args = build_args(messages, model, session_id)
      stdin_content = extract_user_prompt(messages)

      process = CliProcess.new(
        command: command,
        args: args,
        scrub_env_vars: scrub_env_vars,
        idle_timeout: @timeout,
      )

      process.run(stdin_content) do |line|
        parser.parse_line(line).each do |event|
          @last_events << event
          yield event
        end
      end
    end

    private def build_args(
      messages : Array(Message),
      model : String?,
      session_id : String?
    ) : Array(String)
      args = session_id ? resume_args(session_id) : fresh_args
      args = args + model_arg(model || @default_model) if (model || !@default_model.empty?)

      system_prompt = messages.find(&.role.system?).try(&.content)
      if system_prompt && !system_prompt.empty?
        args = args + system_prompt_arg(system_prompt)
      end

      args
    end

    # Args for a brand-new run. Subclasses append a fresh --session-id so
    # the caller can capture and later resume it.
    protected def fresh_args : Array(String)
      base_args + ["--session-id", UUID.random.to_s]
    end

    # CLI backends take the user turn on stdin, not via chat-history JSON.
    # On resume, the prior turns already live in the CLI's own session file,
    # so we only need to send the newest user message.
    private def extract_user_prompt(messages : Array(Message)) : String
      last_user = messages.reverse.find(&.role.user?)
      last_user.try(&.content) || ""
    end
  end
end
