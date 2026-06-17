require "./base_grammar"

module Llamero
  # One tool invocation the model emits as structured JSON — parsed by the normal
  # `chat_structured` machinery (it maps to a grammar, so it parses like any other
  # structured output). `tool` selects which fields are meaningful:
  #
  # - `write_file` → `path` + `content` (the primary "act": write Crystal to the
  #   AED-correct location)
  # - `read_file`  → `path`
  # - `look_up`    → `query`   (look something up instead of fabricating)
  # - `run`        → `command` (e.g. `crystal build`, `crystal spec`)
  #
  # ```
  # {"tool":"write_file","path":"src/billing/lock_account.cr","content":"class Billing::LockAccount\n..."}
  # ```
  class ToolCall < BaseGrammar
    property tool : String = ""
    property path : String = ""
    property content : String = ""
    property query : String = ""
    property command : String = ""

    # The tool names the agentic harness knows how to execute.
    KNOWN = %w(write_file read_file look_up run)

    def known? : Bool
      KNOWN.includes?(tool)
    end
  end

  # The agentic response shape: an inline PLAN (the "plan-then-act" reasoning we
  # train into non-thinking bases like Gemma — for thinking-capable bases the
  # harness can route a separate <thinking> block and leave this as the committed
  # plan) followed by the ORDERED tool calls to execute. Parsed like any
  # structured output via `chat_structured(messages, Llamero::AgenticPlan)`.
  #
  # ```
  # {"plan":"Process manager Billing::LockAccount; perform calls validate, lock, notify; file at src/billing/lock_account.cr.",
  #  "tool_calls":[{"tool":"write_file","path":"src/billing/lock_account.cr","content":"..."}]}
  # ```
  class AgenticPlan < BaseGrammar
    property plan : String = ""
    property tool_calls : Array(ToolCall) = [] of ToolCall
  end
end
