module Llamero::Native
  # Compiles a generated Amber/Crystal snippet against the REAL Amber (and Grant)
  # framework and reports whether it type-checks — the only signal that catches
  # fabricated framework APIs and wrong macro usage (amber-lsp is regex-only and
  # cannot). Wired as FSDDReward's `compiles` tier.
  #
  # It works because Crystal type-checks a class's macros (column/before_action/
  # validates_*), base-class resolution, and signatures at DEFINITION time, but
  # only deep-checks a method BODY when that method is instantiated. So just
  # DEFINING the snippet validates its framework usage without false-failing on
  # domain references (`User.find`) buried in uncalled bodies. Undefined top-level
  # domain constants referenced at class-body level are auto-stubbed so a real
  # association/model doesn't fail merely because `Customer` isn't defined here.
  #
  # ```
  # judge = AmberCompileJudge.new(amber_root: "/path/to/amber", grant_root: "/path/to/grant")
  # judge.compile?(snippet)  # => true if it type-checks against the framework
  # reward = FSDDReward.new(compiles: ->(c : String) { judge.compile?(c) })
  # ```
  class AmberCompileJudge
    getter work_dir : Path

    FRAMEWORK_HEADS = Set{
      "Amber", "Grant", "Granite", "JSON", "YAML", "XML", "HTTP", "DB", "URI", "UUID",
      "Time", "Int", "Int8", "Int16", "Int32", "Int64", "Int128", "UInt8", "UInt16",
      "UInt32", "UInt64", "UInt128", "Float", "Float32", "Float64", "BigDecimal", "BigInt",
      "BigRational", "String", "Bool", "Char", "Symbol", "Array", "Hash", "Set", "Tuple",
      "NamedTuple", "Nil", "Object", "Exception", "ArgumentError", "IO", "File", "Dir",
      "Path", "Process", "Random", "Math", "Regex", "Slice", "Bytes", "Log", "Channel",
      "Fiber", "Mutex", "Reference", "Value", "Struct", "Enum", "Comparable", "Enumerable",
      "Iterator", "Indexable", "Number", "Pointer", "Deque", "Range", "Proc", "Box",
    }

    def initialize(@amber_root : String, @grant_root : String? = nil, work_dir : Path | String | Nil = nil)
      @work_dir = Path[work_dir || File.tempname("amber-judge")].expand
      @ready = false
      @cache = {} of String => Bool
    end

    # Build a judge from AMBER_REPO / GRANT_REPO env vars, or nil if unset/missing.
    def self.from_env : AmberCompileJudge?
      amber = ENV["AMBER_REPO"]?
      return nil unless amber && Dir.exists?(amber)
      grant = ENV["GRANT_REPO"]?
      new(amber, (grant if grant && Dir.exists?(grant)))
    end

    def available? : Bool
      Dir.exists?(@amber_root)
    end

    # True iff the snippet type-checks against the real framework.
    def compile?(code : String) : Bool
      return false unless available?
      return @cache[code] if @cache.has_key?(code)
      setup
      harness = String.build do |s|
        s << "require \"amber\"\n"
        grant = @grant_root
        s << "require \"grant\"\n" if grant
        # Stub undefined domain constants as Grant models when Grant is available
        # (so association/model references resolve), else as plain classes.
        stub_super = grant ? " < Grant::Base" : ""
        domain_stubs(code).each { |c| s << "class " << c << stub_super << "; end\n" }
        s << code << '\n'
      end
      File.write(@work_dir.join("harness.cr").to_s, harness)
      ok = build_ok?
      @cache[code] = ok
      ok
    end

    # Top-level Capitalized constants referenced but not defined in the snippet
    # and not part of the framework/stdlib — stubbed so class-body references
    # (associations, typed properties) resolve.
    def domain_stubs(code : String) : Array(String)
      defined = Set(String).new
      code.scan(/\b(?:class|struct|module|enum|alias|lib)\s+([A-Z]\w*)/) { |m| defined << m[1] }
      used = Set(String).new
      code.scan(/\b([A-Z]\w*)(?:::[A-Z]\w*)*/) do |m|
        head = m[1]
        used << head unless FRAMEWORK_HEADS.includes?(head)
      end
      (used - defined).to_a.sort
    end

    private def build_ok? : Bool
      Process.run("crystal", ["build", "--no-codegen", "harness.cr"],
        chdir: @work_dir.to_s, output: Process::Redirect::Close, error: Process::Redirect::Close).success?
    rescue
      false
    end

    private def setup : Nil
      return if @ready
      lib_dir = @work_dir.join("lib")
      Dir.mkdir_p(lib_dir.to_s)
      symlink(@amber_root, lib_dir.join("amber"))
      shard = @work_dir.join("shard.yml")
      File.write(shard.to_s, "name: amber-judge\nversion: 0.1.0\ncrystal: \">= 1.0.0\"\n") unless File.exists?(shard.to_s)
      if g = @grant_root
        symlink(g, lib_dir.join("grant"))
        {"db", "sqlite3", "pg", "mysql"}.each do |dep|
          src = File.join(g, "lib", dep)
          symlink(src, lib_dir.join(dep)) if Dir.exists?(src)
        end
      end
      @ready = true
    end

    private def symlink(target : String, link : Path) : Nil
      return if File.symlink?(link.to_s) || File.exists?(link.to_s)
      File.symlink(target, link.to_s)
    rescue
      # best-effort; an unresolved symlink just means those requires fail (-> false)
    end
  end
end
