require "file_utils"

module Llamero::Native
  # Self-labeling compiler-error-repair pair generator. Take a KNOWN-GOOD Crystal
  # program, apply a mutation that introduces a realistic error, compile the
  # mutant to capture the REAL compiler diagnostic, and emit
  # `(broken code + real error) -> original code`. The fix is guaranteed correct
  # (it's the code that already compiled) and the error is real — no fabrication
  # is possible. Teaches the model to read `crystal build` errors and fix them,
  # and it is deterministically gradable for RL (does the model's fix compile?).
  module ErrorRepair
    extend self

    record RepairPair, broken : String, error : String, fixed : String, mutation : String

    # ---- mutations: pure String -> String? (nil when not applicable) ----

    # Remove the last bare `end` — unbalances the program (syntax error).
    def drop_last_end(code : String) : String?
      lines = code.split('\n')
      idx = lines.rindex { |l| l.strip == "end" }
      return nil unless idx
      (lines[0...idx] + lines[(idx + 1)..]).join('\n')
    end

    RETURN_TYPES = %w(Int32 String Bool Float64 Int64 Char Symbol)

    # Swap an explicit return type to an incompatible one (type error).
    def swap_return_type(code : String) : String?
      RETURN_TYPES.each do |t|
        if m = code.match(/(def\s+[\w?!]+[^\n:]*:\s*)#{t}(\s*\n)/)
          repl = RETURN_TYPES.find { |x| x != t } || "String"
          return code.sub(m[0], "#{m[1]}#{repl}#{m[2]}")
        end
      end
      nil
    end

    # Drop the last character of a method call name (undefined method).
    def typo_method_call(code : String) : String?
      if m = code.match(/\.([a-z_]{3,}[a-z])\b/)
        name = m[1]
        return code.sub(".#{name}", ".#{name[0...name.size - 1]}")
      end
      nil
    end

    # Remove a `require "..."` line (undefined constant, if it was used).
    def drop_require(code : String) : String?
      lines = code.split('\n')
      idx = lines.index { |l| l.lstrip.starts_with?("require \"") }
      return nil unless idx
      (lines[0...idx] + lines[(idx + 1)..]).join('\n')
    end

    # Corrupt a TYPE ANNOTATION to a non-existent type (undefined constant). This
    # is checked at DEFINITION time, so it surfaces without instantiating the
    # code — unlike type-mismatch/arity/nil errors, which need a usage harness
    # (queued: see development_docs). Broadly applicable (most typed code).
    def corrupt_type_annotation(code : String) : String?
      # skip comment lines; match a `: Capitalized` annotation in real code
      code.each_line.with_index do |line, i|
        next if line.lstrip.starts_with?('#')
        if m = line.match(/(:\s*)([A-Z][A-Za-z0-9]+)(\??[\s,)\]\n])/)
          return code.sub(line, line.sub(m[0], "#{m[1]}#{m[2]}Zz#{m[3]}"))
        end
      end
      nil
    end

    MUTATIONS = %w(corrupt-type drop-require wrong-return-type typo-method drop-end)

    def mutate(code : String, name : String) : String?
      case name
      when "drop-end"          then drop_last_end(code)
      when "wrong-return-type" then swap_return_type(code)
      when "typo-method"       then typo_method_call(code)
      when "drop-require"      then drop_require(code)
      when "corrupt-type"      then corrupt_type_annotation(code)
      end
    end

    # ---- compile (the deterministic labeler) ----

    def compiles?(code : String) : Bool
      compile_error(code).nil?
    end

    # The cleaned `crystal build --no-codegen` diagnostic, or nil if it compiled.
    def compile_error(code : String) : String?
      dir = File.tempname("erepair")
      Dir.mkdir_p(dir)
      path = File.join(dir, "broken.cr")
      File.write(path, code)
      err = IO::Memory.new
      status = Process.run("crystal", ["build", "--no-codegen", "broken.cr"],
        chdir: dir, output: Process::Redirect::Close, error: err)
      return nil if status.success?
      clean_error(err.to_s)
    rescue
      nil
    ensure
      FileUtils.rm_rf(dir) if dir
    end

    private def clean_error(stderr : String) : String
      stderr.split('\n')
        .reject { |l| l.includes?("MallocStackLogging") || l.starts_with?("Showing last frame") || l.includes?("--error-trace") }
        .join('\n').strip
    end

    # All verified repair pairs derivable from one known-good program.
    def from_program(code : String) : Array(RepairPair)
      return [] of RepairPair unless compiles?(code) # original must be clean
      pairs = [] of RepairPair
      MUTATIONS.each do |name|
        broken = mutate(code, name)
        next unless broken && broken != code
        err = compile_error(broken)
        next unless err # mutation must actually break it
        pairs << RepairPair.new(broken, err, code, name)
      end
      pairs
    end

    # Format a repair pair as a directive training pair (prompt -> completion).
    def to_training_pair(pair : RepairPair) : {String, String}
      prompt = String.build do |s|
        s << "The following Crystal code fails to compile with this error:\n\n"
        s << pair.error << "\n\n"
        s << "Fix the code and return the complete corrected program.\n\n"
        s << pair.broken
      end
      {prompt, pair.fixed}
    end
  end
end
