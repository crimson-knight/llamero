#!/usr/bin/env crystal
#
# Smoke test for the Claude CLI backend (Llamero v2 Phase 1).
#
# Exercises the real `claude` binary — not fixtures, not mocks — so we catch
# flag drift, JSONL-frame drift, env-scrub regressions, and anything else
# that a unit spec with canned data would miss.
#
# Prerequisites
#   - `claude` on PATH, logged in via `claude login`
#   - Run from any directory; the shard is required by absolute path
#
# Usage
#   crystal run scripts/smoke/claude_cli_backend.cr
#
# Exit code
#   0 — every check passed
#   1 — at least one check failed (details printed per-check)

require "../../src/clients/cli/claude_cli_client"

CHECKS        = [] of {String, Bool, String}
OVERALL_START = Time.instant

def log_check(name : String, passed : Bool, detail : String = "") : Nil
  CHECKS << {name, passed, detail}
  status = passed ? "\e[32mPASS\e[0m" : "\e[31mFAIL\e[0m"
  line   = "  [#{status}] #{name}"
  line  += " — #{detail}" unless detail.empty?
  puts line
end

def section(title : String) : Nil
  puts
  puts "\e[1m#{title}\e[0m"
end

# ── preflight ─────────────────────────────────────────────────────────────
section "Preflight"

claude_path = Process.find_executable("claude")
unless claude_path
  log_check("claude binary on PATH", false, "install Claude Code CLI and run `claude login`")
  puts
  puts "\e[31mAborting: cannot run the smoke test without `claude`.\e[0m"
  exit 1
end
log_check("claude binary on PATH", true, claude_path)

# ── check 1: simple chat ──────────────────────────────────────────────────
section "Check 1: simple chat round-trip"

client = Llamero::ClaudeCliClient.new(timeout: 2.minutes)
response : Llamero::ChatResponse(Nil)? = nil

begin
  response = client.chat([
    Llamero::Message.system("You are a terse calculator. Answer with digits only."),
    Llamero::Message.user("What is 17 + 25?"),
  ])
rescue ex
  log_check("chat() does not raise", false, ex.message || ex.class.name)
  log_check("ChatResponse has non-empty content", false, "skipped")
  log_check("session id captured", false, "skipped")
  log_check("usage reports input_tokens > 0", false, "skipped")
else
  log_check("chat() does not raise", true)
  r = response.not_nil!
  log_check("ChatResponse has non-empty content", !r.content.strip.empty?, r.content[0..80])
  log_check("session id captured", !client.last_session_id.nil?, client.last_session_id || "nil")
  log_check("usage reports input_tokens > 0", r.usage.input_tokens > 0, "input=#{r.usage.input_tokens} output=#{r.usage.output_tokens}")
  if r.content.includes?("42")
    log_check("answer contains expected 42", true)
  else
    log_check("answer contains expected 42", false, "got: #{r.content.strip}")
  end
end

# ── check 2: session resume ───────────────────────────────────────────────
section "Check 2: session resume continuity"

first_sid = client.last_session_id
if first_sid.nil?
  log_check("resume: prior session captured", false, "no session id from check 1")
  log_check("resume: response references prior turn", false, "skipped")
else
  log_check("resume: prior session captured", true, first_sid)
  begin
    follow_up = client.chat(
      [Llamero::Message.user("What number did I just ask you to compute, in words?")],
      session_id: first_sid,
    )
  rescue ex
    log_check("resume: chat() does not raise", false, ex.message || ex.class.name)
    log_check("resume: response references prior turn", false, "skipped")
  else
    log_check("resume: chat() does not raise", true)
    text = follow_up.content.downcase
    references_prior = text.includes?("forty-two") || text.includes?("forty two") || text.includes?("42")
    log_check("resume: response references prior turn", references_prior, follow_up.content.strip[0..120])
  end
end

# ── check 3: streaming ────────────────────────────────────────────────────
section "Check 3: streaming"

chunks = [] of String
begin
  client.chat_stream([Llamero::Message.user("Count from 1 to 3, one number per line.")]) do |chunk|
    chunks << chunk
  end
rescue ex
  log_check("chat_stream() does not raise", false, ex.message || ex.class.name)
else
  log_check("chat_stream() does not raise", true)
  log_check("received at least one streaming chunk", !chunks.empty?, "#{chunks.size} chunks")
  joined = chunks.join
  log_check("streaming output contains 1, 2, 3", joined.includes?("1") && joined.includes?("2") && joined.includes?("3"), joined.strip[0..80])
end

# ── check 4: env scrub survives a real spawn ──────────────────────────────
section "Check 4: env scrubbing under a real spawn"

ENV["ANTHROPIC_API_KEY"] = "bogus-value-that-would-break-auth-if-inherited"
begin
  scrub_client = Llamero::ClaudeCliClient.new(timeout: 90.seconds)
  r = scrub_client.chat([Llamero::Message.user("Say 'ok' and nothing else.")])
  log_check("spawn succeeds with bogus ANTHROPIC_API_KEY set in parent", !r.content.strip.empty?, r.content.strip[0..40])
rescue ex
  log_check("spawn succeeds with bogus ANTHROPIC_API_KEY set in parent", false, "if this says 'authentication failed', env scrub is broken. #{ex.message}")
ensure
  ENV.delete("ANTHROPIC_API_KEY")
end

# ── check 5: watchdog with a fake command ─────────────────────────────────
section "Check 5: watchdog aborts a stalled child"

fake_stall = Llamero::CliProcess.new(
  command: "sh",
  args: ["-c", "echo starting; exec sleep 60"],
  idle_timeout: 1.seconds,
)

watchdog_start = Time.instant
begin
  fake_stall.run(nil) { |_| }
  log_check("watchdog fires", false, "stalled command completed without timeout")
rescue Llamero::CliIdleTimeoutError
  elapsed = Time.instant - watchdog_start
  log_check("watchdog fires", elapsed < 5.seconds, "elapsed=#{elapsed.total_seconds.round(2)}s")
rescue ex
  log_check("watchdog fires", false, "unexpected error: #{ex.class}: #{ex.message}")
end

# ── summary ───────────────────────────────────────────────────────────────
section "Summary"

passed = CHECKS.count { |_, ok, _| ok }
failed = CHECKS.size - passed
total  = CHECKS.size
dur    = Time.instant - OVERALL_START

if failed == 0
  puts "  \e[32m#{passed}/#{total} passed\e[0m in #{dur.total_seconds.round(1)}s"
  exit 0
else
  puts "  \e[31m#{failed}/#{total} failed\e[0m (#{passed} passed) in #{dur.total_seconds.round(1)}s"
  puts
  puts "  Failed checks:"
  CHECKS.each do |name, ok, detail|
    next if ok
    puts "    - #{name}#{detail.empty? ? "" : " — #{detail}"}"
  end
  exit 1
end
