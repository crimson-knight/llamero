require "json"
require "./errors"

module Llamero::Native
  # Abstract boundary between the Crystal runtime API and a native model
  # execution backend.
  #
  # The contract is intentionally small and JSON-based: configuration,
  # adapter stacks, and generation requests cross as JSON strings; results
  # stream back as JSON event frames (see NativeEvent.from_bridge_json).
  # Handles are opaque integer tokens owned by the bridge.
  #
  # Implementations:
  # - MockBridge: deterministic, in-process, runs anywhere. Used by specs
  #   and non-Apple development.
  # - MLXBridge: dlopen-based FFI binding to the Swift MLX runtime dylib.
  #   Real Apple Silicon inference through MLX/Metal.
  abstract class Bridge
    # Picks the best available bridge: the real MLX bridge when its dylib
    # can be found and loaded on this machine, otherwise the mock bridge.
    #
    # The dylib search order is documented on MLXBridge.discover_library_path.
    def self.auto : Bridge
      MLXBridge.try_load || MockBridge.new
    end

    # Human-readable backend name (e.g. "mlx", "mock").
    abstract def name : String

    # True when this bridge performs real native inference.
    abstract def real? : Bool

    # Creates a runtime from a JSON config (model_id, model_path,
    # cache_limit_bytes, ...). Returns an opaque runtime handle.
    abstract def create_runtime(config_json : String) : Int64

    abstract def free_runtime(runtime : Int64) : Nil

    # Creates a session bound to a runtime. Returns an opaque session handle.
    abstract def create_session(runtime : Int64) : Int64

    abstract def free_session(session : Int64) : Nil

    # Loads the base model for a session, yielding JSON event frames
    # (model_load_started/progress/model_loaded or error). The request JSON
    # carries the resolved local model directory ({"model_path": "..."});
    # model downloading happens Crystal-side (see ModelDownloader) because
    # the Swift HuggingFace download path requires a serviced main dispatch
    # queue, which non-Swift hosts do not have.
    abstract def load_model(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil

    # Applies an adapter stack to the resident model, yielding event frames
    # (adapter_activated or error). Must not reload the base model; if a
    # reload was unavoidable the bridge must report it in the event payload.
    abstract def activate_adapters(session : Int64, stack_json : String, &on_event : JSON::Any ->) : Nil

    # Runs one generation, yielding event frames (token_delta /
    # structured_json_delta, then generation_completed, or error). Blocks the
    # calling fiber until generation finishes.
    abstract def generate(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil

    # Trains a LoRA/DoRA adapter on the resident model, yielding event frames
    # (training_progress / training_validation, then training_completed with
    # the artifact path, or error). The bridge must restore the base model's
    # original layers afterwards - training never permanently mutates the
    # resident model. Request JSON carries the dataset dir, output dir, and
    # AdapterTrainingConfig fields.
    abstract def train_adapter(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
  end
end
