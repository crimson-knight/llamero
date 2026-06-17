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

    def run(impl : String, spec_body : String) : SpecResult
      dir = File.tempname("specrun")
      Dir.mkdir_p(dir)
      File.write(File.join(dir, "impl.cr"), impl)
      File.write(File.join(dir, "impl_spec.cr"), wrap(spec_body))
      buf = IO::Memory.new
      status = Process.run("crystal", ["spec", "impl_spec.cr"],
        chdir: dir, output: buf, error: buf)
      SpecResult.new(status.success?, clean(buf.to_s))
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

    # Behavior-changing, compile-preserving edits (NOT compile-breaking ones —
    # a non-compiling mutant would trivially "fail" and prove nothing).
    BEHAVIOR_SUBS = [
      {" + ", " - "}, {" - ", " + "}, {" * ", " // "}, {" < ", " > "},
      {" <= ", " >= "}, {" == ", " != "}, {" && ", " || "}, {"true", "false"},
      {".sort", ""}, {".uniq", ""}, {".reverse", ""}, {".min", ".max"},
    ]

    # Mutants of `impl` that still compile but behave differently.
    def behavior_mutants(impl : String) : Array(String)
      out = [] of String
      seen = Set(String).new
      BEHAVIOR_SUBS.each do |(a, b)|
        next unless impl.includes?(a)
        m = impl.sub(a, b)
        next if m == impl || !seen.add?(m)
        out << m if ErrorRepair.compiles?(m)
      end
      out
    end

    # killed / total behavior mutants (1.0 = every mutant caught).
    def mutation_score(impl : String, spec_body : String) : {Int32, Int32}
      mutants = behavior_mutants(impl)
      killed = mutants.count { |m| !run(m, spec_body).passed }
      {killed, mutants.size}
    end

    # Meaningful = passes the correct impl AND kills at least one behavior mutant.
    def meaningful?(impl : String, spec_body : String) : Bool
      return false unless run(impl, spec_body).passed
      killed, total = mutation_score(impl, spec_body)
      total > 0 && killed >= 1
    end
  end
end
