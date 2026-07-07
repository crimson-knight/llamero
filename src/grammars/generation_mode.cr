require "log"

module Llamero
  # How `chat_structured` constrains the model toward schema-conforming JSON.
  #
  # - `Grammar` - decode-time GBNF constraint against the pinned llama.cpp
  #   build. Forcing it on a backend that cannot constrain decoding RAISES
  #   (never a silent downgrade).
  # - `SchemaPrompt` - inject the JSON Schema into the prompt and parse the
  #   reply (today's native flow).
  # - `Auto` - grammar when the backend can constrain AND the type is under
  #   the GBNF complexity budget; otherwise the backend's honest structured
  #   path (native schema mode on cloud, schema-prompt locally) with an
  #   explicit fallback reason.
  #
  # Symbols autocast: `chat_structured(msgs, T, generation_mode: :auto)`.
  enum GenerationMode
    Auto
    Grammar
    SchemaPrompt
  end

  # Raised when `generation_mode: :grammar` is forced on a backend that cannot
  # constrain decoding (cloud APIs, CLI subprocess clients, the MLX bridge).
  class UnsupportedGenerationModeError < Exception
    getter backend_name : String

    def initialize(@backend_name : String, detail : String)
      super("#{backend_name} cannot honor generation_mode: :grammar - #{detail}")
    end
  end

  # Raised at runtime when `generation_mode: :grammar` is forced for a type
  # whose GBNF exceeds the complexity budget (or is refused, e.g. recursion).
  # The compile-time surface for the same refusal is calling `T.to_gbnf`
  # directly, which `{% raise %}`s during compilation.
  class GrammarBudgetExceededError < Exception
    getter schema_name : String
    getter reason : String

    def initialize(@schema_name : String, @reason : String)
      super("GBNF for #{schema_name} was refused: #{reason}. Use generation_mode: :auto (schema-prompt fallback) or :schema_prompt, or simplify the type.")
    end
  end

  module Gbnf
    Log = ::Log.for("llamero.gbnf")

    @@warned = Set(String).new
    @@warned_mutex = Mutex.new

    # One-time-per-process warning when :auto falls back from grammar to
    # schema-prompt for a type. Crystal has no stable macro-warning primitive,
    # so this runtime surface is the guaranteed one.
    def self.warn_fallback_once(schema_name : String, reason : String) : Nil
      first = @@warned_mutex.synchronize { @@warned.add?(schema_name) }
      return unless first
      Log.warn { "generation_mode :auto fell back to schema-prompt for #{schema_name}: #{reason}" }
    end

    # :nodoc:
    def self.reset_warnings! : Nil
      @@warned_mutex.synchronize { @@warned.clear }
    end
  end
end
