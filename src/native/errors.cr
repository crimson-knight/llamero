# Errors raised by the native (on-device) runtime.
#
# Native errors are explicit and recoverable where possible. Every error
# carries a stable bridge/backend code, a recoverability hint, and whether
# the base model remains loaded so callers can decide between retrying,
# reloading, or surfacing the failure.
module Llamero::Native
  # Base class for all native runtime errors.
  class NativeError < Exception
    # Stable machine-readable code from the bridge/backend (e.g. "model_load_failed")
    getter code : String

    # Whether the operation can plausibly be retried without a full reload
    getter recoverable : Bool

    # Whether the base model is still resident after this error
    getter base_model_loaded : Bool

    def initialize(
      message : String,
      @code : String = "native_error",
      @recoverable : Bool = false,
      @base_model_loaded : Bool = false
    )
      super(message)
    end
  end

  # The base model failed to load into memory.
  class ModelLoadError < NativeError
    def initialize(message : String, code : String = "model_load_failed", recoverable : Bool = true)
      super(message, code, recoverable, base_model_loaded: false)
    end
  end

  # The requested model id/path does not resolve to a usable model artifact.
  class ModelUnavailableError < NativeError
    def initialize(message : String, code : String = "model_unavailable")
      super(message, code, recoverable: false, base_model_loaded: false)
    end
  end

  # An adapter name was not found in the registry.
  class AdapterNotFoundError < NativeError
    getter adapter_name : String

    def initialize(@adapter_name : String, message : String? = nil, base_model_loaded : Bool = true)
      super(message || "Adapter not registered: #{@adapter_name}", "adapter_not_found", recoverable: true, base_model_loaded: base_model_loaded)
    end
  end

  # An adapter artifact exists but cannot be applied to the loaded base model
  # (wrong base model, wrong rank/format, etc.). Recovery may require a reload.
  class AdapterIncompatibleError < NativeError
    def initialize(message : String, base_model_loaded : Bool = true)
      super(message, "adapter_incompatible", recoverable: false, base_model_loaded: base_model_loaded)
    end
  end

  # Activating or deactivating an adapter stack failed at the bridge level.
  class AdapterActivationError < NativeError
    def initialize(message : String, base_model_loaded : Bool = true)
      super(message, "adapter_activation_failed", recoverable: true, base_model_loaded: base_model_loaded)
    end
  end

  # Training an adapter failed. The base model remains loaded (the bridge
  # restores the original layers on failure).
  class AdapterTrainingError < NativeError
    def initialize(message : String, base_model_loaded : Bool = true)
      super(message, "adapter_training_failed", recoverable: true, base_model_loaded: base_model_loaded)
    end
  end

  # Generation failed mid-stream. The base model normally remains loaded.
  class GenerationError < NativeError
    def initialize(message : String, code : String = "generation_failed", base_model_loaded : Bool = true)
      super(message, code, recoverable: true, base_model_loaded: base_model_loaded)
    end
  end

  # The native bridge library could not be found or initialized.
  class BridgeUnavailableError < NativeError
    def initialize(message : String)
      super(message, "bridge_unavailable", recoverable: false, base_model_loaded: false)
    end
  end

  # The current platform cannot run the real native runtime (e.g. not
  # macOS on Apple Silicon). The mock bridge remains available everywhere.
  class UnsupportedPlatformError < NativeError
    def initialize(message : String = "Native MLX runtime requires macOS on Apple Silicon")
      super(message, "unsupported_platform", recoverable: false, base_model_loaded: false)
    end
  end

  # The model produced output that could not be parsed into the requested
  # schema. Carries everything needed to debug or retry: the raw text, the
  # schema name, and the adapter stack that was active.
  class StructuredParseError < NativeError
    getter raw_text : String
    getter schema_name : String
    getter adapter_stack : AdapterStack?

    def initialize(
      message : String,
      @raw_text : String,
      @schema_name : String,
      @adapter_stack : AdapterStack? = nil
    )
      super(message, "structured_parse_failed", recoverable: true, base_model_loaded: true)
    end
  end

  # Operation attempted on a session in the wrong state (e.g. chat before
  # load_model, or any call after close).
  class SessionStateError < NativeError
    def initialize(message : String, base_model_loaded : Bool = false)
      super(message, "session_state_invalid", recoverable: false, base_model_loaded: base_model_loaded)
    end
  end

  # --- Audio track (speech-to-text / text-to-speech) errors ---

  # Base class for errors raised by the native audio runtime (Parakeet ASR
  # and Kokoro TTS through the FluidAudio bridge or its mock).
  class AudioError < NativeError
    def initialize(message : String, code : String = "audio_error", recoverable : Bool = true)
      super(message, code, recoverable, base_model_loaded: false)
    end
  end

  # Speech-to-text failed (missing/unreadable audio file, model download or
  # load failure, or a decoding error). The runtime stays usable; retry with
  # a valid file.
  class TranscriptionError < AudioError
    def initialize(message : String)
      super(message, "transcription_failed", recoverable: true)
    end
  end

  # Speaker diarization or speaker-attributed transcription failed. The
  # runtime stays usable; retry with a valid speech file or different
  # diarization config.
  class DiarizationError < AudioError
    def initialize(message : String)
      super(message, "diarization_failed", recoverable: true)
    end
  end

  # Text-to-speech failed (empty text, model download or load failure, or a
  # synthesis error). The runtime stays usable.
  class SpeechSynthesisError < AudioError
    def initialize(message : String)
      super(message, "speak_failed", recoverable: true)
    end
  end
end
