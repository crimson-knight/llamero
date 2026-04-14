require "./events"

module Llamero
  # Raised when a CLI subprocess exits non-zero. Surfaces captured stderr.
  class CliProcessError < APIError
    getter exit_code : Int32
    getter stderr : String

    def initialize(command : String, @exit_code : Int32, @stderr : String)
      super("#{command} exited #{@exit_code}: #{@stderr.lines.first?.try(&.strip) || "(no stderr)"}")
    end
  end

  # Raised when no stdout activity is seen for `idle_timeout`. The process
  # is SIGTERM'd, then SIGKILL'd if it doesn't exit within the grace period.
  class CliIdleTimeoutError < APIError
    def initialize(command : String, timeout : Time::Span)
      super("#{command} stalled: no output for #{timeout.total_seconds.to_i}s")
    end
  end

  # Spawns an external AI CLI, pipes the prompt on stdin, yields stdout
  # lines as they arrive, and enforces an idle-timeout watchdog.
  #
  # The child's environment is built fresh from ENV with `scrub_env_vars`
  # keys deleted — this stops ambient shell overrides (ANTHROPIC_API_KEY,
  # OAUTH tokens, OTEL exporters, etc.) from steering the child CLI away
  # from its own logged-in state.
  class CliProcess
    DEFAULT_IDLE_TIMEOUT = 120.seconds
    KILL_GRACE_PERIOD    = 2.seconds

    getter command : String
    getter args : Array(String)
    getter scrub_env_vars : Array(String)
    getter idle_timeout : Time::Span

    def initialize(
      @command : String,
      @args : Array(String),
      @scrub_env_vars : Array(String) = [] of String,
      @idle_timeout : Time::Span = DEFAULT_IDLE_TIMEOUT
    )
    end

    # Run the subprocess. Yields each stdout line to the block. Blocks
    # until the process exits or the watchdog kills it. Returns stderr.
    #
    # Raises CliIdleTimeoutError if the watchdog fires, or
    # CliProcessError if the process exits non-zero.
    def run(stdin_content : String?, & : String -> Nil) : String
      env = build_child_env
      process = Process.new(
        @command,
        @args,
        env: env,
        clear_env: true,
        input: :pipe,
        output: :pipe,
        error: :pipe,
      )

      feed_stdin(process, stdin_content)
      last_activity = Time.instant
      activity_mutex = Mutex.new
      stalled = false

      line_ch = stream_stdout(process) do
        activity_mutex.synchronize { last_activity = Time.instant }
      end
      stderr_ch = capture_stderr(process)

      watchdog_done = Channel(Nil).new
      spawn do
        loop do
          sleep 100.milliseconds
          break if line_ch.closed?
          idle = activity_mutex.synchronize { Time.instant - last_activity }
          if idle >= @idle_timeout
            stalled = true
            kill_process(process)
            break
          end
        end
        watchdog_done.send(nil)
      end

      while line = line_ch.receive?
        yield line
      end
      watchdog_done.receive

      if stalled
        stderr = stderr_ch.receive? || ""
        process.wait
        raise CliIdleTimeoutError.new(@command, @idle_timeout)
      end

      stderr = stderr_ch.receive? || ""
      status = process.wait

      unless status.success?
        raise CliProcessError.new(@command, status.exit_code, stderr)
      end

      stderr
    end

    private def build_child_env : Hash(String, String)
      env = {} of String => String
      ENV.each { |k, v| env[k] = v }
      @scrub_env_vars.each { |k| env.delete(k) }
      env
    end

    private def feed_stdin(process : Process, content : String?) : Nil
      spawn do
        if content
          process.input.print(content)
          process.input.flush
        end
        process.input.close
      rescue IO::Error
        # Child closed stdin before we finished writing; nothing to do.
      end
    end

    private def stream_stdout(process : Process, &on_activity : -> Nil) : Channel(String)
      ch = Channel(String).new(64)
      spawn do
        process.output.each_line do |line|
          on_activity.call
          ch.send(line)
        end
      rescue IO::Error
        # pipe closed; fall through to close
      ensure
        ch.close
      end
      ch
    end

    private def capture_stderr(process : Process) : Channel(String)
      ch = Channel(String).new(1)
      spawn do
        ch.send(process.error.gets_to_end)
      rescue IO::Error
        ch.send("")
      end
      ch
    end

    private def kill_process(process : Process) : Nil
      process.signal(Signal::TERM) rescue nil
      elapsed = 0.seconds
      tick = 100.milliseconds
      while elapsed < KILL_GRACE_PERIOD
        break unless process.exists?
        sleep tick
        elapsed += tick
      end
      process.signal(Signal::KILL) rescue nil if process.exists?
    end
  end
end
