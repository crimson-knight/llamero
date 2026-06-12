require "json"
require "../config/storage"
require "./bridge"

module Llamero::Native
  # Minimal libdl declarations for loading the Swift bridge at runtime.
  # Using dlopen instead of @[Link] keeps the MLX dylib out of normal shard
  # installs: apps without the native library still compile and run (they
  # get the mock bridge from Bridge.auto).
  lib LibDL
    RTLD_NOW = 0x2

    fun dlopen(file : LibC::Char*, mode : LibC::Int) : Void*
    fun dlsym(handle : Void*, symbol : LibC::Char*) : Void*
    fun dlerror : LibC::Char*
  end

  # FFI binding to the Swift MLX runtime dylib (libLlameroMLXBridge.dylib).
  #
  # ## C ABI contract (implemented by native/llamero-mlx)
  #
  # ```c
  # typedef void (*llamero_event_callback)(const char *json_event, void *user_data);
  #
  # int64_t llamero_mlx_runtime_create(const char *json_config);   // > 0 handle, <= 0 failure
  # void    llamero_mlx_runtime_free(int64_t runtime);
  # int64_t llamero_mlx_session_create(int64_t runtime);           // > 0 handle, <= 0 failure
  # void    llamero_mlx_session_free(int64_t session);
  # int32_t llamero_mlx_session_load_model(int64_t session, const char *json_request, llamero_event_callback cb, void *user_data);
  # int32_t llamero_mlx_session_activate_adapters(int64_t session, const char *json_stack, llamero_event_callback cb, void *user_data);
  # int32_t llamero_mlx_session_generate(int64_t session, const char *json_request, llamero_event_callback cb, void *user_data);
  # int32_t llamero_mlx_session_train_adapter(int64_t session, const char *json_config, llamero_event_callback cb, void *user_data);
  # ```
  #
  # All callbacks are invoked synchronously on the calling thread; the Swift
  # side bridges its async generation onto the caller via an internal event
  # queue. Errors are reported both as a nonzero status and as an `error`
  # event frame so messages flow through one path.
  class MLXBridge < Bridge
    # Trampoline for event callbacks: unboxes the Crystal block from
    # user_data and hands it the JSON frame. Must stay non-closure so it has
    # a bare function pointer.
    EVENT_TRAMPOLINE = ->(json : LibC::Char*, user_data : Void*) do
      Box(Proc(String, Nil)).unbox(user_data).call(String.new(json))
    end

    getter library_path : String

    @dylib : Void*
    @runtime_create : Proc(LibC::Char*, Int64)
    @runtime_free : Proc(Int64, Nil)
    @session_create : Proc(Int64, Int64)
    @session_free : Proc(Int64, Nil)
    @session_load_model : Proc(Int64, LibC::Char*, Void*, Void*, Int32)
    @session_activate_adapters : Proc(Int64, LibC::Char*, Void*, Void*, Int32)
    @session_generate : Proc(Int64, LibC::Char*, Void*, Void*, Int32)
    @session_train_adapter : Proc(Int64, LibC::Char*, Void*, Void*, Int32)

    # Locates the bridge dylib. Search order:
    # 1. LLAMERO_MLX_LIB environment variable
    # 2. The in-repo Swift build products (native/llamero-mlx/.build/...)
    # 3. The shard's build products when llamero is a dependency
    #    (lib/llamero/native/llamero-mlx/.build/...)
    # 4. Configured storage lib directory (build.sh installs here by default)
    # 5. /usr/local/lib/libLlameroMLXBridge.dylib
    def self.discover_library_path : String?
      if from_env = ENV["LLAMERO_MLX_LIB"]?
        return from_env if File.exists?(from_env)
      end

      [
        "native/llamero-mlx/.build/release/libLlameroMLXBridge.dylib",
        "native/llamero-mlx/.build/arm64-apple-macosx/release/libLlameroMLXBridge.dylib",
        "lib/llamero/native/llamero-mlx/.build/release/libLlameroMLXBridge.dylib",
        "lib/llamero/native/llamero-mlx/.build/arm64-apple-macosx/release/libLlameroMLXBridge.dylib",
        Llamero::Storage.lib_dir.join("libLlameroMLXBridge.dylib").to_s,
        "/usr/local/lib/libLlameroMLXBridge.dylib",
      ].find { |candidate| File.exists?(candidate) }
    end

    # Returns a ready bridge when running on Apple Silicon macOS and the
    # dylib can be found and loaded; nil otherwise.
    def self.try_load : MLXBridge?
      {% if flag?(:darwin) && flag?(:aarch64) %}
        if path = discover_library_path
          begin
            return new(path)
          rescue BridgeUnavailableError
            return nil
          end
        end
      {% end %}
      nil
    end

    def initialize(@library_path : String)
      handle = LibDL.dlopen(@library_path, LibDL::RTLD_NOW)
      if handle.null?
        raise BridgeUnavailableError.new("Failed to dlopen #{@library_path}: #{dl_error}")
      end
      @dylib = handle

      @runtime_create = Proc(LibC::Char*, Int64).new(symbol("llamero_mlx_runtime_create"), Pointer(Void).null)
      @runtime_free = Proc(Int64, Nil).new(symbol("llamero_mlx_runtime_free"), Pointer(Void).null)
      @session_create = Proc(Int64, Int64).new(symbol("llamero_mlx_session_create"), Pointer(Void).null)
      @session_free = Proc(Int64, Nil).new(symbol("llamero_mlx_session_free"), Pointer(Void).null)
      @session_load_model = Proc(Int64, LibC::Char*, Void*, Void*, Int32).new(symbol("llamero_mlx_session_load_model"), Pointer(Void).null)
      @session_activate_adapters = Proc(Int64, LibC::Char*, Void*, Void*, Int32).new(symbol("llamero_mlx_session_activate_adapters"), Pointer(Void).null)
      @session_generate = Proc(Int64, LibC::Char*, Void*, Void*, Int32).new(symbol("llamero_mlx_session_generate"), Pointer(Void).null)
      @session_train_adapter = Proc(Int64, LibC::Char*, Void*, Void*, Int32).new(symbol("llamero_mlx_session_train_adapter"), Pointer(Void).null)
    end

    def name : String
      "mlx"
    end

    def real? : Bool
      true
    end

    def create_runtime(config_json : String) : Int64
      handle = @runtime_create.call(config_json.to_unsafe)
      if handle <= 0
        raise BridgeUnavailableError.new("MLX bridge failed to create runtime (status #{handle})")
      end
      handle
    end

    def free_runtime(runtime : Int64) : Nil
      @runtime_free.call(runtime)
    end

    def create_session(runtime : Int64) : Int64
      handle = @session_create.call(runtime)
      if handle <= 0
        raise BridgeUnavailableError.new("MLX bridge failed to create session (status #{handle})")
      end
      handle
    end

    def free_session(session : Int64) : Nil
      @session_free.call(session)
    end

    def load_model(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @session_load_model.call(session, request_json.to_unsafe, callback, user_data)
      end
    end

    def activate_adapters(session : Int64, stack_json : String, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @session_activate_adapters.call(session, stack_json.to_unsafe, callback, user_data)
      end
    end

    def generate(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @session_generate.call(session, request_json.to_unsafe, callback, user_data)
      end
    end

    def train_adapter(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      with_events(on_event) do |callback, user_data|
        @session_train_adapter.call(session, request_json.to_unsafe, callback, user_data)
      end
    end

    # Wraps a C call that streams event frames. Listener exceptions are
    # stashed and re-raised after the native call returns so Crystal
    # exceptions never unwind through Swift frames.
    private def with_events(on_event : JSON::Any ->, &call : (Void*, Void*) -> Int32) : Nil
      deferred_error : Exception? = nil
      saw_error_frame = false

      receiver = ->(json : String) do
        return if deferred_error
        begin
          frame = JSON.parse(json)
          saw_error_frame = true if frame["event"]?.try(&.as_s) == "error"
          on_event.call(frame)
        rescue ex
          deferred_error = ex
        end
        nil
      end

      boxed = Box.box(receiver)
      status = call.call(EVENT_TRAMPOLINE.pointer.as(Void*), boxed)

      if failure = deferred_error
        raise failure
      end

      # A nonzero status with no error frame means the bridge failed before
      # it could report properly (e.g. unknown handle).
      if status != 0 && !saw_error_frame
        raise NativeError.new("MLX bridge call failed with status #{status}", "bridge_call_failed")
      end
    end

    private def symbol(name : String) : Void*
      pointer = LibDL.dlsym(@dylib, name)
      if pointer.null?
        raise BridgeUnavailableError.new("Missing symbol #{name} in #{@library_path}: #{dl_error}")
      end
      pointer
    end

    private def dl_error : String
      message = LibDL.dlerror
      message.null? ? "unknown dlopen error" : String.new(message)
    end
  end
end
