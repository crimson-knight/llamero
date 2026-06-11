require "json"

module Llamero::Native
  # Timing and memory metrics for one base model load.
  struct ModelLoadMetrics
    include JSON::Serializable

    getter model_id : String
    getter load_time_ms : Float64
    getter memory_bytes : Int64
    # True when this load replaced an already-resident model. The target
    # behavior for adapter changes is that this stays false.
    getter reloaded : Bool

    def initialize(@model_id : String, @load_time_ms : Float64 = 0.0, @memory_bytes : Int64 = 0_i64, @reloaded : Bool = false)
    end
  end

  # Per-generation performance metrics reported by the bridge.
  struct GenerationMetrics
    include JSON::Serializable

    getter input_tokens : Int32
    getter output_tokens : Int32
    getter tokens_per_second : Float64
    getter time_to_first_token_ms : Float64
    getter total_time_ms : Float64

    def initialize(
      @input_tokens : Int32 = 0,
      @output_tokens : Int32 = 0,
      @tokens_per_second : Float64 = 0.0,
      @time_to_first_token_ms : Float64 = 0.0,
      @total_time_ms : Float64 = 0.0
    )
    end
  end
end
