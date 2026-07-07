require "../config/storage"

module Llamero
  # Third backend track: grammar-constrained structured generation through a
  # PINNED llama.cpp build. See development_docs and README ("Grammar-constrained
  # structured output") for the architecture.
  #
  # llama.cpp releases near-daily with breaking flag/API changes, so llamero
  # supports EXACTLY ONE build at a time. The pin below is the single source of
  # truth: the installer script builds it, the runtime probe enforces it, and
  # generated GBNF is validated against it. The probe NEVER accepts a llama.cpp
  # found on PATH, even a working one - "works on my machine because brew" is
  # exactly the false positive this design removes.
  module LlamaCpp
    # NOTE: scripts/install_llamacpp.sh parses the PIN_TAG / PIN_COMMIT lines
    # with sed. Keep the `NAME = "value"` shape if you edit them.
    #
    # Pin bumps are deliberate PRs gated by the 7-step revalidation in
    # README (build, flag smoke, .gbnf enforcement smoke, fixture suite,
    # benchmark smoke, changelog) and are at least a minor llamero release.
    PIN_TAG    = "b9902"
    PIN_COMMIT = "55edb2de442b50be0a29c2ed2ec88488560a96c5"

    SUPPORTED_BUILD = {
      tag:            PIN_TAG,
      commit:         PIN_COMMIT,
      binary:         "llama-completion", # upstream renamed llama-cli -> llama-completion
      required_flags: ["--grammar", "--grammar-file", "--json-schema", "--json-schema-file"],
    }

    # Short commit fragment as printed by `llama-completion --version`
    # (e.g. "version: 1 (55edb2d)"). Shallow tag clones report build number 1,
    # so the probe matches the commit fragment, never the build number.
    def self.commit_fragment : String
      PIN_COMMIT[0, 7]
    end

    # Pinned builds are installed OUTSIDE lib/ (which shards regenerates),
    # keyed by tag so multiple pins can coexist across llamero versions:
    #   ~/.llamero/llamacpp/<tag>/bin/llama-completion
    # (or $LLAMERO_HOME/llamacpp/<tag>/bin when the storage root is moved).
    def self.install_dir : Path
      Llamero.storage_root.join("llamacpp", PIN_TAG)
    end

    def self.pinned_binary_path : Path
      install_dir.join("bin", SUPPORTED_BUILD[:binary])
    end

    def self.install_hint : String
      "Run: sh scripts/install_llamacpp.sh   (from lib/llamero/ when llamero is installed as a dependency)\n" \
      "If you installed with `shards install --skip-postinstall`, this setup step is required."
    end

    # Mandatory fail-closed gate in front of every :grammar call.
    #
    # Checks, in order:
    #   1. the binary exists at the pinned storage-root path (PATH is never consulted)
    #   2. `--version` output contains the pinned commit fragment
    #   3. `--help` advertises every flag the grammar seam relies on
    #
    # The result is cached per process (per runner) because the probe spawns
    # subprocesses. Raises Llamero::LlamaCppUnavailableError with the exact fix
    # command on any failure.
    class Probe
      @@cache = {} of String => String?
      @@cache_mutex = Mutex.new

      def initialize(@runner : Runner = SubprocessRunner.new)
      end

      # Returns the failure reason, or nil when the pinned build is usable.
      def failure_reason : String?
        key = cache_key
        @@cache_mutex.synchronize do
          return @@cache[key] if @@cache.has_key?(key)
        end
        reason = compute_failure_reason
        @@cache_mutex.synchronize { @@cache[key] = reason }
        reason
      end

      def ok? : Bool
        failure_reason.nil?
      end

      def check! : Nil
        if reason = failure_reason
          raise LlamaCppUnavailableError.new(reason)
        end
      end

      # :nodoc:
      def self.reset_cache! : Nil
        @@cache_mutex.synchronize { @@cache.clear }
      end

      private def cache_key : String
        "#{@runner.class.name}:#{@runner.object_id}:#{LlamaCpp.pinned_binary_path}"
      end

      private def compute_failure_reason : String?
        path = LlamaCpp.pinned_binary_path

        unless @runner.executable?(path)
          return "No compatible #{SUPPORTED_BUILD[:binary]} found at the pinned path.\nDetected: none at #{path}"
        end

        version = @runner.run(path, ["--version"], timeout: 30.seconds)
        version_text = "#{version.output}\n#{version.error_output}"
        unless version_text.includes?(LlamaCpp.commit_fragment)
          detected = version_text.lines.find(&.includes?("version")).try(&.strip) || version_text.strip.lines.first?.try(&.strip) || "unknown version output"
          return "Wrong llama.cpp build at the pinned path.\nDetected: #{path} -> #{detected}"
        end

        help = @runner.run(path, ["--help"], timeout: 30.seconds)
        help_text = "#{help.output}\n#{help.error_output}"
        missing = SUPPORTED_BUILD[:required_flags].reject { |flag| help_text.includes?(flag) }
        unless missing.empty?
          return "Pinned llama.cpp build is missing required flags: #{missing.join(", ")}.\nDetected: #{path}"
        end

        nil
      end
    end
  end

  # Grammar mode requires the pinned llama.cpp build and refuses anything else.
  class LlamaCppUnavailableError < Exception
    def initialize(detail : String)
      super(
        "llamero grammar mode requires pinned llama.cpp #{LlamaCpp::PIN_TAG} (#{LlamaCpp::PIN_COMMIT}). #{detail}\n#{LlamaCpp.install_hint}"
      )
    end
  end
end
