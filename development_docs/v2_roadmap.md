# Llamero v2.0 Roadmap

**Status:** draft, 2026-04-14
**Supersedes:** `development_docs/improvements_to_make.md` (brain dump, pre-v1.0)
**Motivating consumer:** AmberClaw — Crystal reimplementation of OpenClaw's agent loop. Llamero must be the substrate it sits on.

---

## 1. Where we are (v1.0.0)

**What ships today** (`src/`):
- `Llamero::Client` abstract — user subclasses, declares `primary:` + `fallbacks:` providers, `chat` / `chat_structured` / `chat_stream` with automatic failover, retry config, `on_fallback` / `on_retry` callbacks.
- HTTP provider clients: `OpenAIClient`, `AnthropicClient`, `GroqClient`, `OpenRouterClient` — all subclass `Llamero::APIClient`.
- `Message` struct with `MessageRole::{System,User,Assistant,Tool}`, `Usage`, `ChatResponse(T)`.
- `Feature` enum: `StructuredOutput`, `ToolCalling`, `Streaming`, `Embeddings`, `Vision` — declared, but `ToolCalling` has no implementation path.
- `JsonSchemaBuilder` (v2 of the grammar system — JSON Schema, not GBNF).
- Legacy: `BasePrompt` + `PromptMessage` (instruction-model tag wrapping), `BaseGrammar` (llama.cpp grammars). Both are now dead weight for the v2 direction.
- `ProviderConfig` + `ModelMapping` for cross-provider model aliases.
- `APIError` taxonomy: `AuthenticationError`, `RateLimitError`, `QuotaExceededError`, `ServerError`, `ModelNotFoundError`, `InvalidRequestError`.

**What's proven:** multi-provider failover, retry/backoff, structured outputs, streaming.

## 2. What v2 must add (AmberClaw-driven)

| # | Capability | Why AmberClaw needs it | Where it lives |
|---|---|---|---|
| 1 | **CLI-subprocess backend** (`claude`, `codex`, etc.) | AmberClaw's whole premise: use the real Claude Code CLI as the inference engine so ToS stays clean. No HTTP path. | `src/clients/cli/` |
| 2 | **JSONL streaming parser** with typed events | `claude -p --output-format stream-json` emits session-init, message_start, content_block_delta, tool_use, tool_result, message_stop. AmberClaw needs typed events, not raw JSON. | `src/clients/cli/stream_parser.cr` |
| 3 | **Session-id capture + resume** | `--session-id <uuid>` on first call; `--resume <uuid>` after. OpenClaw sessions are JSONL files on disk; we mirror. | `src/sessions/` |
| 4 | **Tool calling** (end-to-end) | Every autonomy pattern (sub-agent delegation, think-plan-do) is built on tool use. Feature flag exists; implementation does not. | `src/tools/` |
| 5 | **Typed message graph** (Turn / ToolInteraction / Delegation) | Context editing requires structure — you can't drop a tool call mid-thread with a flat `Array(Message)`. | `src/conversation/` |
| 6 | **Context editing policies** | Remove/compress tool exchanges, sub-agent chatter, failed plan attempts from the wire format while keeping them in working memory. | `src/conversation/context_policy.cr` |
| 7 | **Working memory** (queryable, separate from wire context) | When a message gets edited out, its *outcome* must still be reachable so the agent can reflect. | `src/conversation/working_memory.cr` |
| 8 | **Prompt cache markers** (Anthropic `cache_control`) | Cost/latency — critical for a loop that re-hits the same system prompt. Anthropic only for now; no-op on others. | `src/conversation/cache_markers.cr` |
| 9 | **Workflow primitive** — Think / Plan / Do / Reflect | One of Llamero's headline features per the brain dump. Budget-bounded loop with per-stage tracing. | `src/workflows/` |
| 10 | **Env-scrub + process supervision** for CLI spawn | OpenClaw scrubs `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, etc. before spawning `claude` so ambient shell vars can't steer it. Must replicate. | `src/clients/cli/process.cr` |
| 11 | **Idle-timeout watchdog** per request | Stalled streams hang the loop. AmberClaw's autonomy dies if we don't abort cleanly. | `src/clients/cli/watchdog.cr` |

**Explicitly dropped in v2:** `BaseGrammar` (llama.cpp GBNF), `BasePrompt` instruction-model tag wrapping, `composed_prompt_chain_for_instruction_models`. Move to `src/legacy/` for one release, then delete.

## 3. Design sketches

### 3a. CLI backend

```crystal
# src/clients/cli/cli_client.cr
abstract class Llamero::CliClient < Llamero::APIClient
  abstract def command : String                # "claude" | "codex" | ...
  abstract def base_args : Array(String)       # always-on flags
  abstract def resume_args(session_id : String) : Array(String)
  abstract def model_arg(model : String) : Array(String)
  abstract def system_prompt_arg(prompt : String) : Array(String)
  abstract def scrub_env_vars : Array(String)  # keys to delete before spawn

  def chat(messages, model = nil, temperature = nil, max_tokens = nil) : ChatResponse(Nil)
    prompt = messages_to_stdin(messages)
    with_process(prompt, model) do |events|
      collect_assistant_text(events)
    end
  end

  def chat_stream(messages, model = nil, ...) : Nil
    prompt = messages_to_stdin(messages)
    with_process(prompt, model) do |events|
      events.each { |ev| yield_text(ev) { |chunk| yield chunk } }
    end
  end
end

# src/clients/cli/claude_cli_client.cr
class Llamero::ClaudeCliClient < Llamero::CliClient
  def command : String
    "claude"
  end

  def base_args : Array(String)
    ["-p", "--output-format", "stream-json", "--include-partial-messages",
     "--verbose", "--setting-sources", "user",
     "--permission-mode", "bypassPermissions"]
  end

  def resume_args(session_id)
    base_args + ["--resume", session_id]
  end

  def model_arg(model)
    ["--model", model]
  end

  def system_prompt_arg(prompt)
    ["--append-system-prompt", prompt]
  end

  # Scrub list straight from openclaw/extensions/anthropic/cli-shared.ts
  def scrub_env_vars
    %w[
      ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CODE_OAUTH_REFRESH_TOKEN
      CLAUDE_CONFIG_DIR ANTHROPIC_BASE_URL ANTHROPIC_VERTEX_PROJECT_ID
      OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS
      OTEL_METRICS_EXPORTER OTEL_LOGS_EXPORTER OTEL_TRACES_EXPORTER
    ]
  end
end
```

Process supervision (`src/clients/cli/process.cr`): `Process.new(command, args, env: scrubbed_env, input: :pipe, output: :pipe, error: :pipe)`. Spawn in a fiber, pipe prompt to stdin, parse stdout line-by-line through `StreamParser`, emit events to a `Channel(CliEvent)`. Watchdog: reset on each event; if `idle_timeout` elapses, SIGTERM → wait 2s → SIGKILL.

### 3b. JSONL stream parser — typed events

```crystal
abstract struct Llamero::CliEvent; end

struct Llamero::SessionInit < Llamero::CliEvent
  getter session_id : String
  getter model : String
end

struct Llamero::MessageStart < Llamero::CliEvent
  getter message_id : String
end

struct Llamero::ContentDelta < Llamero::CliEvent
  getter kind : Kind   # Text | Thinking
  getter text : String
end

struct Llamero::ToolUse < Llamero::CliEvent
  getter tool_use_id : String
  getter name : String
  getter input : JSON::Any
end

struct Llamero::ToolResult < Llamero::CliEvent
  getter tool_use_id : String
  getter content : String
  getter is_error : Bool
end

struct Llamero::MessageStop < Llamero::CliEvent
  getter stop_reason : String
  getter usage : Usage
end

struct Llamero::Usage                # extend existing
  property cache_creation_input_tokens : Int32 = 0
  property cache_read_input_tokens : Int32 = 0
end
```

One parser class per emitting CLI; dispatch by probing the first frame's shape. Start with Claude's format; Codex/Qwen parsers land in later PRs.

### 3c. Typed message graph

```crystal
abstract class Llamero::ConversationNode
  property id : String = UUID.random.to_s
  property created_at : Time = Time.utc
  property include_in_context : Bool = true   # context-editing toggle
  property summary : String? = nil            # compressed form when excluded
end

class Llamero::Turn < ConversationNode
  property role : MessageRole
  property text : String
end

class Llamero::ToolInteraction < ConversationNode
  property tool_use : ToolUse
  property tool_result : ToolResult
  # When .include_in_context is false, summary replaces both on the wire.
end

class Llamero::SubAgentDelegation < ConversationNode
  property agent_name : String
  property instruction : String
  property final_result : String
  property internal_conversation : Conversation   # nested, its own context policy
end

class Llamero::Conversation
  property nodes : Array(ConversationNode)
  property system_prompt : String
  property cache_markers : Array(Int32)        # indexes after which a cache point lives
  property working_memory : WorkingMemory

  def to_wire_messages(provider : Symbol) : Array(Message)
    # Walk nodes, apply include_in_context?, swap excluded nodes for their summaries,
    # insert Anthropic cache_control on marked boundaries when provider == :anthropic.
  end
end
```

`WorkingMemory` is a simple keyed store (`Hash(String, JSON::Any)`) the agent writes to via a built-in `memory.write` tool. Excluded nodes still live in `nodes` — they're just hidden from the wire. This lets Reflect read outcomes of prior attempts.

### 3d. Context-editing policies

```crystal
module Llamero::ContextPolicy
  abstract def apply(conversation : Conversation) : Nil
end

class Llamero::DropCompletedToolCalls
  include ContextPolicy
  def apply(conv)
    conv.nodes.each_with_index do |n, i|
      next unless n.is_a?(ToolInteraction)
      next if i >= conv.nodes.size - 2   # keep the 2 most recent
      n.include_in_context = false
      n.summary ||= "[Tool #{n.tool_use.name} ran, result elided]"
    end
  end
end

class Llamero::CompressFailedPlans; ...; end
class Llamero::SummarizeSubAgentChatter; ...; end
```

Policies run before each `chat` call. Order matters and is user-controlled. Default stack: `[DropCompletedToolCalls, CompressFailedPlans]`.

### 3e. Workflow primitive

```crystal
# src/workflows/think_plan_do_reflect.cr
class Llamero::Workflows::ThinkPlanDoReflect
  def initialize(@client : Client, @budget : Budget,
                 @on_stage : Proc(Stage, StageResult, Nil)? = nil)
  end

  enum Stage; Think; Plan; Do; Reflect; end

  def run(goal : String, & : Stage -> String) : WorkflowResult
    conv = Conversation.new(system_prompt: stage_prompt(Stage::Think))
    loop do
      think_result = run_stage(Stage::Think, conv) { |c| yield Stage::Think }
      plan_result  = run_stage(Stage::Plan, conv)  { |c| yield Stage::Plan }
      do_result    = run_stage(Stage::Do, conv)    { |c| yield Stage::Do }
      refl_result  = run_stage(Stage::Reflect, conv) { |c| yield Stage::Reflect }
      return WorkflowResult.complete(conv) if refl_result.done?
      break if @budget.exhausted?
    end
    WorkflowResult.budget_exhausted(conv)
  end
end

struct Llamero::Budget
  property max_iterations : Int32 = 5
  property max_input_tokens : Int32 = 500_000
  property max_cost_usd : Float64 = 10.0
  property max_wall_seconds : Int32 = 600
end
```

Traceability: every stage writes an entry to a `WorkflowTrace` (JSONL on disk at `tmp/workflows/<workflow_id>.jsonl`) with stage, tokens, cost, outcome. That's the file AmberClaw will show users.

## 4. Phasing

**Phase 1 — CLI backend MVP (2 weeks).** Items 1, 2, 3, 10, 11. Claude CLI only. Success: `Llamero::ClaudeCliClient.new.chat(...)` round-trips a prompt end-to-end with session resume working, env scrubbed, watchdog killing stalled streams.

**Phase 2 — Tool calling + typed graph (2 weeks).** Items 4, 5. All four existing HTTP providers + CLI. Success: a tool-calling demo that runs on both Anthropic HTTP and Claude CLI, producing identical `ToolInteraction` nodes.

**Phase 3 — Context editing + working memory (1.5 weeks).** Items 6, 7. Success: a 100-turn conversation that stays under 50k context tokens via default policy stack.

**Phase 4 — Prompt caching + workflow primitive (1.5 weeks).** Items 8, 9. Success: `ThinkPlanDoReflect.run("research these files")` completes, respecting a budget, with cache reads visible in `Usage`.

**Phase 5 — Codex / Qwen CLI adapters (later).** Parser-per-CLI plus a `Llamero::CliClient` subclass. No rush — Claude CLI unlocks AmberClaw.

Total: ~7 weeks focused work before AmberClaw proper begins.

## 5. Decisions locked (2026-04-14)

1. **Version:** v2.0, breaking. Grammars + `BasePrompt` instruction-model path removed. Legacy aliases for one release, then deleted.
2. **Brand:** **Llamero** (double-L, Spanish — "one who wrangles llamas"). Shard name stays `llamero`; all marketing/docs copy uses Llamero.
3. **Sessions disk schema:** mirror OpenClaw's JSONL-per-session layout exactly. Same file must be resumable by a vanilla `claude --resume <id>` invocation. Zero-cost interop.
4. **Tool DSL:** Crystal macro (`tool "name" do ... end`) generates JSON Schema at compile time. Single source of truth, no hand-written schema files.

## 6. Still open — decide before AmberClaw build starts (not blocking Llamero v2)

**Hierarchy vs flat for AmberClaw.**
- **Hierarchy** (current EA pattern): EA → team-lead → worker. Clear accountability, role specialization, team-lead curates context before delegating. Costs tokens on coordination, can deadlock at middle layer.
- **Flat** (OpenClaw's stance, VISION.md refuses manager-of-managers): one agent spawns a peer session via `sessions_spawn`, communicates via `sessions_send`, no middle managers. Cheaper, harder to deadlock, but loses the "team lead curates context" move.
- Both shapes run on the same Llamero v2 substrate, so this only blocks AmberClaw architecture work, not Phase 1–4 here.

## 7. Non-goals for v2

- Channel plugins (Telegram, Slack, etc.). Belongs in AmberClaw, not Llamero.
- Multi-agent orchestration protocol. Belongs in AmberClaw.
- Canvas / A2UI UI generation. Out of scope forever — different product.
- MCP client. Defer to v2.1+ once the core is stable; `--mcp-config` pass-through in the CLI adapter is enough for now.

## 8. Risk register

- **Claude CLI JSONL format is unstable.** Mitigation: pin parser to a CLI version range, version-detect at startup via `claude --version`, refuse to run outside known range with a clear error.
- **Process supervision on Windows.** Out of scope for v2; document "Unix only" until someone wants it.
- **Cost attribution when CLI omits usage frames.** Fall back to post-hoc token estimation; flag estimated vs reported in `Usage`.
- **Env scrub list drift.** OpenClaw updates theirs on every model release. Mitigation: copy their file into `development_docs/cli_scrub_list_upstream.txt` at each release and diff.
