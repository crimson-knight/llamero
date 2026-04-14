require "spec"
require "../../../src/clients/cli/cli_process"

# Helpers that construct small shell one-liners to use as stand-ins for the
# real AI CLI. All specs in this file are hermetic — no `claude` binary
# needed on PATH.

private def echo_env_cmd : Array(String)
  ["-c", %(echo "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-__UNSET__}"; echo "CLAUDE_CODE_OAUTH_TOKEN=${CLAUDE_CODE_OAUTH_TOKEN:-__UNSET__}"; echo "KEEP_ME=${KEEP_ME:-__UNSET__}")]
end

private def cat_stdin_cmd : Array(String)
  ["-c", "cat"]
end

private def slow_output_cmd(delay_seconds : Int32) : Array(String)
  # `exec sleep` replaces the shell so Process.signal lands on sleep
  # directly — otherwise the shell blocks waiting for its child and the
  # signal can't propagate.
  ["-c", "echo first; exec sleep #{delay_seconds}"]
end

private def failing_cmd : Array(String)
  ["-c", "echo 'oh no' 1>&2; exit 17"]
end

describe Llamero::CliProcess do
  describe "#run env scrubbing" do
    it "strips scrubbed env vars from the child environment" do
      ENV["ANTHROPIC_API_KEY"] = "should-be-gone"
      ENV["CLAUDE_CODE_OAUTH_TOKEN"] = "also-gone"
      ENV["KEEP_ME"] = "keep-me-value"

      process = Llamero::CliProcess.new(
        command: "sh",
        args: echo_env_cmd,
        scrub_env_vars: ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"],
        idle_timeout: 5.seconds,
      )

      lines = [] of String
      process.run(nil) { |line| lines << line.chomp }

      lines.should contain("ANTHROPIC_API_KEY=__UNSET__")
      lines.should contain("CLAUDE_CODE_OAUTH_TOKEN=__UNSET__")
      lines.should contain("KEEP_ME=keep-me-value")
    ensure
      ENV.delete("ANTHROPIC_API_KEY")
      ENV.delete("CLAUDE_CODE_OAUTH_TOKEN")
      ENV.delete("KEEP_ME")
    end
  end

  describe "#run stdin piping" do
    it "pipes stdin_content to the child and captures stdout" do
      process = Llamero::CliProcess.new(
        command: "sh",
        args: cat_stdin_cmd,
        idle_timeout: 5.seconds,
      )

      lines = [] of String
      process.run("hello from stdin\n") { |line| lines << line.chomp }

      lines.should eq(["hello from stdin"])
    end
  end

  describe "#run error handling" do
    it "raises CliProcessError when the child exits non-zero" do
      process = Llamero::CliProcess.new(
        command: "sh",
        args: failing_cmd,
        idle_timeout: 5.seconds,
      )

      expect_raises(Llamero::CliProcessError, /oh no/) do
        process.run(nil) { |_| }
      end
    end
  end

  describe "#run watchdog" do
    it "kills the child and raises CliIdleTimeoutError when stdout goes silent" do
      process = Llamero::CliProcess.new(
        command: "sh",
        args: slow_output_cmd(10),
        idle_timeout: 1.seconds,
      )

      started = Time.utc
      expect_raises(Llamero::CliIdleTimeoutError) do
        process.run(nil) { |_| }
      end
      elapsed = Time.utc - started

      # Watchdog should fire in ~1s + <2s grace; must be well under the
      # 10s natural runtime, which proves we actually killed the child.
      elapsed.should be < 5.seconds
    end
  end
end
