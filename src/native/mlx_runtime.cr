require "json"
require "./bridge"
require "./mock_bridge"
require "./mlx_bridge"
require "./adapters"
require "./model_downloader"
require "./model_session"

module Llamero::Native
  # Owns native runtime configuration and the resident-model lifecycle.
  #
  # A runtime selects the model, memory policy, and bridge, then hands out
  # ModelSession instances. On Apple Silicon with the Swift MLX bridge built,
  # Bridge.auto picks real Metal-accelerated inference; everywhere else it
  # falls back to the deterministic mock bridge so apps and specs still run.
  #
  # ```crystal
  # runtime = Llamero::Native::MLXRuntime.new(
  #   model_id: "mlx-community/Qwen3-0.6B-4bit",
  #   fallback_model_id: "mlx-community/SmolLM-135M-Instruct-4bit",
  #   cache_limit_bytes: 64 * 1024 * 1024
  # )
  #
  # session = runtime.start_session
  # session.load_model
  # ```
  class MLXRuntime
    getter model_id : String
    # Optional local directory containing the model, used instead of
    # downloading by id.
    getter model_path : String?
    getter fallback_model_id : String?
    getter cache_limit_bytes : Int64?
    getter bridge : Bridge
    getter adapters : AdapterRegistry

    @runtime_handle : Int64

    def initialize(
      @model_id : String,
      @model_path : String? = nil,
      @fallback_model_id : String? = nil,
      cache_limit_bytes : Int | Nil = nil,
      @bridge : Bridge = Bridge.auto,
      @adapters : AdapterRegistry = AdapterRegistry.new,
      @downloader : ModelDownloader = ModelDownloader.new
    )
      raise ArgumentError.new("model_id cannot be blank") if @model_id.blank?
      @cache_limit_bytes = cache_limit_bytes.try(&.to_i64)
      @sessions = [] of ModelSession
      @closed = false
      @runtime_handle = @bridge.create_runtime(config_json)
    end

    # True when this runtime performs real native inference (vs. the mock).
    def real_bridge? : Bool
      @bridge.real?
    end

    def bridge_name : String
      @bridge.name
    end

    def closed? : Bool
      @closed
    end

    # Creates a new session against this runtime. The session starts
    # unloaded; call ModelSession#load_model to bring the model into memory.
    def start_session : ModelSession
      raise SessionStateError.new("Runtime is closed") if @closed
      handle = @bridge.create_session(@runtime_handle)
      session = ModelSession.new(
        @bridge, handle, @model_id, @adapters,
        model_path: @model_path, downloader: @downloader
      )
      @sessions << session
      session
    end

    # Closes all sessions and frees the bridge runtime.
    def close : Nil
      return if @closed
      @sessions.each do |session|
        session.close unless session.closed?
      end
      @bridge.free_runtime(@runtime_handle)
      @closed = true
    end

    private def config_json : String
      JSON.build do |json|
        json.object do
          json.field "model_id", @model_id
          json.field "model_path", @model_path if @model_path
          json.field "fallback_model_id", @fallback_model_id if @fallback_model_id
          json.field "cache_limit_bytes", @cache_limit_bytes if @cache_limit_bytes
        end
      end
    end
  end
end
