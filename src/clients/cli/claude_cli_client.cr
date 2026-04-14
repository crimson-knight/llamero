require "./cli_client"
require "./claude_stream_parser"

module Llamero
  # Concrete CliClient for Anthropic's `claude` CLI (Claude Code).
  #
  # Spawns `claude -p` in streaming JSONL mode with an env scrubbed of any
  # ambient credentials or telemetry overrides, so the child CLI uses its
  # own `claude login` state and nothing else. This follows the
  # integration surface Anthropic has sanctioned for third-party hosts.
  #
  # ```crystal
  # client = Llamero::ClaudeCliClient.new
  # response = client.chat([Llamero::Message.user("Hello!")])
  # puts response.content
  # puts client.last_session_id        # => "uuid" — pass back to resume
  #
  # response = client.chat(
  #   [Llamero::Message.user("What did I just say?")],
  #   session_id: client.last_session_id,
  # )
  # ```
  class ClaudeCliClient < CliClient
    DEFAULT_MODEL = "sonnet"

    # Env keys stripped before spawning `claude` so ambient shell overrides
    # cannot redirect the child to a different provider, endpoint, token
    # source, config root, or telemetry bootstrap.
    ENV_SCRUB_LIST = %w[
      ANTHROPIC_API_KEY
      CLAUDE_CODE_OAUTH_TOKEN
      CLAUDE_CODE_OAUTH_REFRESH_TOKEN
      CLAUDE_CONFIG_DIR
      ANTHROPIC_BASE_URL
      ANTHROPIC_VERTEX_PROJECT_ID
      CLOUD_ML_REGION
      OTEL_EXPORTER_OTLP_ENDPOINT
      OTEL_EXPORTER_OTLP_HEADERS
      OTEL_METRICS_EXPORTER
      OTEL_LOGS_EXPORTER
      OTEL_TRACES_EXPORTER
    ]

    def provider_name : String
      "ClaudeCLI"
    end

    protected def get_default_model : String
      DEFAULT_MODEL
    end

    def command : String
      "claude"
    end

    def base_args : Array(String)
      [
        "-p",
        "--output-format", "stream-json",
        "--include-partial-messages",
        "--verbose",
        "--setting-sources", "user",
        "--permission-mode", "bypassPermissions",
      ]
    end

    def resume_args(session_id : String) : Array(String)
      base_args + ["--resume", session_id]
    end

    def model_arg(model : String) : Array(String)
      ["--model", model]
    end

    def system_prompt_arg(prompt : String) : Array(String)
      ["--append-system-prompt", prompt]
    end

    def scrub_env_vars : Array(String)
      ENV_SCRUB_LIST
    end

    def new_parser : CliStreamParser
      ClaudeStreamParser.new
    end
  end
end
