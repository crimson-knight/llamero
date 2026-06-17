require "file_utils"

module Llamero::Native
  # Runs a generated `crystal spec` against an implementation and reports whether
  # it passes. This is the spec-gate for the spec-generation corpus AND the
  # spec-pass reward for RL — "the generated test actually passes against the
  # code" is a deterministic, high-signal label.
  #
  # The spec body references the implementation as `./impl`; the runner wires the
  # `require "spec"` + `require "./impl"` and runs `crystal spec`.
  #
  # ```
  # res = Llamero::Native::SpecRunner.run(impl_code, spec_body)
  # res.passed  # => true if every example passed
  # ```
  module SpecRunner
    extend self

    record SpecResult, passed : Bool, output : String

    # Generated specs can DEADLOCK (concurrency/`sleep`), so every run is bounded
    # by a timeout — a timed-out spec is a FAIL (and the deadlocked binary is
    # swept). Without this the gate hangs forever on one bad candidate.
    def run(impl : String, spec_body : String, timeout : Time::Span = 15.seconds) : SpecResult
      dir = File.tempname("specrun")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "impl.cr"), impl)
      File.write(File.join(dir, "impl_spec.cr"), wrap(spec_body))
      buf = IO::Memory.new
      process = Process.new("crystal", ["spec", "--no-color", "impl_spec.cr"],
        chdir: dir, output: buf, error: buf)
      # Explicit timeout: whichever fiber sends first wins (buffered channel).
      result = Channel(Process::Status?).new(1)
      spawn { result.send(process.wait) rescue result.send(nil) }
      spawn { sleep timeout; result.send(nil) }
      if status = result.receive
        SpecResult.new(status.success?, clean(buf.to_s))
      else
        process.terminate(graceful: false) rescue nil
        # the deadlocked spec is a compiled grandchild of `crystal spec` — sweep it
        Process.run("pkill", ["-9", "-f", "crystal-run-spec.tmp"]) rescue nil
        SpecResult.new(false, "TIMEOUT after #{timeout.total_seconds.to_i}s")
      end
    rescue ex
      SpecResult.new(false, ex.message || "spec run failed")
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    # Prepend the standard requires unless the spec body already has them.
    def wrap(spec_body : String) : String
      String.build do |s|
        s << "require \"spec\"\n" unless spec_body.includes?(%(require "spec"))
        s << "require \"./impl\"\n" unless spec_body.includes?(%(require "./impl"))
        s << spec_body
        s << '\n'
      end
    end

    private def clean(output : String) : String
      output.split('\n').reject(&.includes?("MallocStackLogging")).join('\n').strip
    end

    # ---- meaningfulness via mutation testing (Codex) ----
    # A passing spec proves nothing on its own (tautologies pass). A spec is
    # MEANINGFUL only if it ALSO catches bugs: mutate the impl in ways that still
    # COMPILE but change behavior, and require the spec to FAIL on at least one
    # (it "kills a mutant"). This separates real tests from `true.should be_true`.

    # Behavior-changing, compile-preserving edits (NOT compile-breaking — a
    # non-compiling mutant would trivially "fail" and prove nothing). Broadened
    # per Codex beyond arithmetic: comparisons + off-by-one boundaries, boolean/
    # predicate inversion, collection/string ops, hash keys/values, defaults.
    BEHAVIOR_SUBS = [
      # arithmetic
      {" + ", " - "}, {" - ", " + "}, {" * ", " // "}, {" // ", " * "},
      # off-by-one / boundaries
      {" + 1", " - 1"}, {" - 1", " + 1"}, {" >= ", " > "}, {" <= ", " < "},
      {" < ", " > "}, {" > ", " < "}, {" == ", " != "},
      # boolean / predicate inversion
      {" && ", " || "}, {" || ", " && "}, {"true", "false"}, {"false", "true"},
      # collection ordering / dedup
      {".sort_by", ".sort_by_NOPE"}, {".sort", ""}, {".uniq", ""}, {".reverse", ""},
      {".min", ".max"}, {".max", ".min"}, {".first", ".last"}, {".last", ".first"},
      # string / hash
      {".upcase", ".downcase"}, {".downcase", ".upcase"}, {".strip", ""},
      {".keys", ".values"}, {".values", ".keys"}, {".abs", ""}, {".ceil", ".floor"},
      # serialization defaults
      {"emit_null: false", "emit_null: true"}, {"emit_null: true", "emit_null: false"},
    ]

    # Up to `limit` mutants of `impl` that still compile but behave differently.
    def behavior_mutants(impl : String, limit : Int32 = 8) : Array(String)
      out = [] of String
      seen = Set(String).new
      BEHAVIOR_SUBS.each do |(a, b)|
        break if out.size >= limit
        next unless impl.includes?(a)
        m = impl.sub(a, b)
        next if m == impl || !seen.add?(m)
        out << m if ErrorRepair.compiles?(m)
      end
      out
    end

    # killed / total behavior mutants.
    def mutation_score(impl : String, spec_body : String) : {Int32, Int32}
      mutants = behavior_mutants(impl)
      killed = mutants.count { |m| !run(m, spec_body).passed }
      {killed, mutants.size}
    end

    # A spec with >=2 `it` blocks, >=2 assertions, that actually names the subject
    # under test — the structural floor for impls that have NO behavior to mutate
    # (pure data structs/JSON), where mutation testing can't apply.
    def structurally_substantial?(impl : String, spec_body : String) : Bool
      its = spec_body.scan(/\bit\s+["(]/).size
      asserts = spec_body.scan(/\.should(?:_not)?\b/).size
      subjects = [] of String
      impl.scan(/(?:class|struct|module|enum)\s+([A-Z]\w*)/) { |m| subjects << m[1] }
      its >= 2 && asserts >= 2 && subjects.any? { |s| spec_body.includes?(s) }
    end

    # Meaningful = passes the correct impl AND EITHER kills a behavior mutant
    # (when mutants exist) OR — when the impl has no behavior to mutate — is
    # structurally substantial and exercises the subject.
    def meaningful?(impl : String, spec_body : String) : Bool
      return false unless run(impl, spec_body).passed
      killed, total = mutation_score(impl, spec_body)
      return killed >= 1 if total > 0
      structurally_substantial?(impl, spec_body)
    end
  end
end
