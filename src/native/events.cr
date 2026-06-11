require "json"
require "./metrics"

module Llamero::Native
  # Typed events produced by a native bridge during model load, adapter
  # activation, and generation. The bridge boundary speaks JSON (one object
  # per event); this layer parses those payloads into Crystal types so app
  # code and the future web UI never touch raw bridge frames.
  #
  # Every event carries the session id, model id, active adapter stack id,
  # and creation time so traces and comparison runs line up.
  abstract struct NativeEvent
    getter session_id : String
    getter model_id : String
    getter adapter_stack_id : String
    getter created_at : Time
    getter raw : JSON::Any

    def initialize(@raw : JSON::Any)
      @session_id = @raw["session_id"]?.try(&.as_s) || ""
      @model_id = @raw["model_id"]?.try(&.as_s) || ""
      @adapter_stack_id = @raw["adapter_stack_id"]?.try(&.as_s) || "base"
      @created_at = @raw["created_at"]?.try { |value| Time.parse_rfc3339(value.as_s) } || Time.utc
    end

    # Parses one bridge JSON event frame into a typed event. Unrecognized
    # frames surface as UnknownNativeEvent so callers can log and keep going.
    def self.from_bridge_json(raw : JSON::Any) : NativeEvent
      case raw["event"]?.try(&.as_s)
      when "model_load_started"   then ModelLoadStartedEvent.new(raw)
      when "model_load_progress"  then ModelLoadProgressEvent.new(raw)
      when "model_loaded"         then ModelLoadedEvent.new(raw)
      when "adapter_activated"    then AdapterActivatedEvent.new(raw)
      when "token_delta"          then TokenDeltaEvent.new(raw)
      when "structured_json_delta" then StructuredJsonDeltaEvent.new(raw)
      when "generation_completed" then GenerationCompletedEvent.new(raw)
      when "training_progress"    then TrainingProgressEvent.new(raw)
      when "training_validation"  then TrainingValidationEvent.new(raw)
      when "training_completed"   then TrainingCompletedEvent.new(raw)
      when "runtime_metric"       then RuntimeMetricEvent.new(raw)
      when "error"                then NativeErrorEvent.new(raw)
      else                             UnknownNativeEvent.new(raw)
      end
    end

    def self.from_bridge_json(json : String) : NativeEvent
      from_bridge_json(JSON.parse(json))
    end
  end

  struct ModelLoadStartedEvent < NativeEvent
  end

  struct ModelLoadProgressEvent < NativeEvent
    # 0.0 to 1.0
    getter progress : Float64
    getter stage : String

    def initialize(raw : JSON::Any)
      super(raw)
      @progress = raw["progress"]?.try(&.as_f) || 0.0
      @stage = raw["stage"]?.try(&.as_s) || "loading"
    end
  end

  struct ModelLoadedEvent < NativeEvent
    getter metrics : ModelLoadMetrics

    def initialize(raw : JSON::Any)
      super(raw)
      @metrics = ModelLoadMetrics.new(
        model_id: @model_id,
        load_time_ms: raw["load_time_ms"]?.try(&.as_f) || 0.0,
        memory_bytes: raw["memory_bytes"]?.try(&.as_i64) || 0_i64,
        reloaded: raw["reloaded"]?.try(&.as_bool) || false
      )
    end
  end

  struct AdapterActivatedEvent < NativeEvent
    # Names of adapters now active, in stack order. Empty means base only.
    getter adapter_names : Array(String)
    # Whether activating this stack forced a base model reload. The target
    # behavior is false; bridges must not hide reloads.
    getter base_model_reloaded : Bool

    def initialize(raw : JSON::Any)
      super(raw)
      @adapter_names = raw["adapter_names"]?.try(&.as_a.map(&.as_s)) || [] of String
      @base_model_reloaded = raw["base_model_reloaded"]?.try(&.as_bool) || false
    end
  end

  struct TokenDeltaEvent < NativeEvent
    getter text : String

    def initialize(raw : JSON::Any)
      super(raw)
      @text = raw["text"]?.try(&.as_s) || ""
    end
  end

  # A delta that is part of a structured-output (JSON) generation. Kept
  # distinct from TokenDelta so accumulators and UIs can treat it differently.
  struct StructuredJsonDeltaEvent < NativeEvent
    getter text : String

    def initialize(raw : JSON::Any)
      super(raw)
      @text = raw["text"]?.try(&.as_s) || ""
    end
  end

  struct GenerationCompletedEvent < NativeEvent
    getter metrics : GenerationMetrics
    getter finish_reason : String

    def initialize(raw : JSON::Any)
      super(raw)
      @finish_reason = raw["finish_reason"]?.try(&.as_s) || "stop"
      @metrics = GenerationMetrics.new(
        input_tokens: raw["input_tokens"]?.try(&.as_i) || 0,
        output_tokens: raw["output_tokens"]?.try(&.as_i) || 0,
        tokens_per_second: raw["tokens_per_second"]?.try(&.as_f) || 0.0,
        time_to_first_token_ms: raw["time_to_first_token_ms"]?.try(&.as_f) || 0.0,
        total_time_ms: raw["total_time_ms"]?.try(&.as_f) || 0.0
      )
    end
  end

  # Periodic training-loss report while an adapter trains on the resident
  # model.
  struct TrainingProgressEvent < NativeEvent
    getter adapter_name : String
    getter iteration : Int32
    getter total_iterations : Int32
    getter loss : Float64
    getter iterations_per_second : Float64
    getter tokens_per_second : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @adapter_name = raw["adapter_name"]?.try(&.as_s) || ""
      @iteration = raw["iteration"]?.try(&.as_i) || 0
      @total_iterations = raw["total_iterations"]?.try(&.as_i) || 0
      @loss = raw["loss"]?.try(&.as_f) || 0.0
      @iterations_per_second = raw["iterations_per_second"]?.try(&.as_f) || 0.0
      @tokens_per_second = raw["tokens_per_second"]?.try(&.as_f) || 0.0
    end
  end

  # Validation-set loss measured during adapter training. This is the
  # "did it actually learn" score for the run so far.
  struct TrainingValidationEvent < NativeEvent
    getter adapter_name : String
    getter iteration : Int32
    getter validation_loss : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @adapter_name = raw["adapter_name"]?.try(&.as_s) || ""
      @iteration = raw["iteration"]?.try(&.as_i) || 0
      @validation_loss = raw["validation_loss"]?.try(&.as_f) || 0.0
    end
  end

  # Adapter training finished and the artifact was written to disk in the
  # mlx_lm adapter format (adapter_config.json + adapters.safetensors).
  struct TrainingCompletedEvent < NativeEvent
    getter adapter_name : String
    getter adapter_path : String
    getter iterations : Int32
    getter final_loss : Float64
    getter final_validation_loss : Float64?
    getter total_time_ms : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @adapter_name = raw["adapter_name"]?.try(&.as_s) || ""
      @adapter_path = raw["adapter_path"]?.try(&.as_s) || ""
      @iterations = raw["iterations"]?.try(&.as_i) || 0
      @final_loss = raw["final_loss"]?.try(&.as_f) || 0.0
      @final_validation_loss = raw["final_validation_loss"]?.try(&.as_f)
      @total_time_ms = raw["total_time_ms"]?.try(&.as_f) || 0.0
    end
  end

  struct RuntimeMetricEvent < NativeEvent
    getter name : String
    getter value : Float64

    def initialize(raw : JSON::Any)
      super(raw)
      @name = raw["name"]?.try(&.as_s) || ""
      @value = raw["value"]?.try(&.as_f) || 0.0
    end
  end

  # An error reported by the bridge as part of the event stream. The session
  # layer converts these into typed NativeError exceptions.
  struct NativeErrorEvent < NativeEvent
    getter message : String
    getter code : String
    getter recoverable : Bool
    getter base_model_loaded : Bool

    def initialize(raw : JSON::Any)
      super(raw)
      @message = raw["message"]?.try(&.as_s) || "Unknown native error"
      @code = raw["code"]?.try(&.as_s) || "native_error"
      @recoverable = raw["recoverable"]?.try(&.as_bool) || false
      @base_model_loaded = raw["base_model_loaded"]?.try(&.as_bool) || false
    end

    def to_error : NativeError
      case @code
      when "model_load_failed"     then ModelLoadError.new(@message)
      when "model_unavailable"     then ModelUnavailableError.new(@message)
      when "adapter_incompatible"  then AdapterIncompatibleError.new(@message, base_model_loaded: @base_model_loaded)
      when "adapter_activation_failed" then AdapterActivationError.new(@message, base_model_loaded: @base_model_loaded)
      when "adapter_training_failed"   then AdapterTrainingError.new(@message, base_model_loaded: @base_model_loaded)
      when "generation_failed"     then GenerationError.new(@message, base_model_loaded: @base_model_loaded)
      else
        NativeError.new(@message, @code, @recoverable, @base_model_loaded)
      end
    end
  end

  # Frame the parser did not recognize. Surfaced so callers can log/trace
  # without crashing when the bridge ships a new frame type.
  struct UnknownNativeEvent < NativeEvent
  end
end
