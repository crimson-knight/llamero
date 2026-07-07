module Llamero
  module LlamaCpp
    # Result of one subprocess invocation of the pinned binary.
    record RunResult,
      output : String,
      error_output : String,
      exit_code : Int32,
      duration : Time::Span

    # Seam between the backend and the operating system, so the whole grammar
    # track is unit-testable without a binary and without network (repo law).
    # SubprocessRunner is the real thing; MockRunner replays scripted results
    # the way MockBridge does for the MLX track.
    abstract class Runner
      abstract def executable?(path : Path) : Bool
      abstract def run(path : Path, args : Array(String), timeout : Time::Span = 5.minutes) : RunResult
    end

    class SubprocessRunner < Runner
      def executable?(path : Path) : Bool
        File.exists?(path) && File.info(path).permissions.owner_execute?
      end

      def run(path : Path, args : Array(String), timeout : Time::Span = 5.minutes) : RunResult
        stdout = IO::Memory.new
        stderr = IO::Memory.new
        started = Time.instant

        process = Process.new(path.to_s, args, output: stdout, error: stderr)
        status_channel = Channel(Process::Status).new(1)
        spawn { status_channel.send(process.wait) }

        status : Process::Status? = nil
        select
        when received = status_channel.receive
          status = received
        when timeout(timeout)
          process.terminate(graceful: false) rescue nil
          status_channel.receive
          raise LlamaCppTimeoutError.new("#{path} #{args.join(" ")} exceeded #{timeout}")
        end

        RunResult.new(
          output: stdout.to_s,
          error_output: stderr.to_s,
          exit_code: status.not_nil!.exit_code,
          duration: Time.instant - started
        )
      end
    end

    # Scripted runner for specs. Queue results with #enqueue; every invocation
    # is recorded (args + any --grammar-file contents captured at call time,
    # since the backend deletes its tempfiles).
    class MockRunner < Runner
      record Invocation,
        path : String,
        args : Array(String),
        grammar_file_contents : String?

      getter invocations = [] of Invocation
      property executable_paths = Set(String).new
      property everything_executable : Bool = true

      @queue = [] of RunResult

      def enqueue(output : String, error_output : String = "", exit_code : Int32 = 0) : Nil
        @queue << RunResult.new(output: output, error_output: error_output, exit_code: exit_code, duration: 5.milliseconds)
      end

      def executable?(path : Path) : Bool
        return true if @everything_executable
        @executable_paths.includes?(path.to_s)
      end

      def run(path : Path, args : Array(String), timeout : Time::Span = 5.minutes) : RunResult
        grammar_contents = nil
        if index = args.index("--grammar-file")
          if grammar_path = args[index + 1]?
            grammar_contents = File.read(grammar_path) if File.exists?(grammar_path)
          end
        end
        @invocations << Invocation.new(path: path.to_s, args: args.dup, grammar_file_contents: grammar_contents)
        raise "MockRunner queue is empty (invocation: #{path} #{args.join(" ")})" if @queue.empty?
        @queue.shift
      end
    end
  end

  # The pinned binary did not finish within the allotted time.
  class LlamaCppTimeoutError < Exception
  end
end
