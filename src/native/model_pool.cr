require "./mlx_runtime"

module Llamero::Native
  # A pool member name did not match any registered model.
  class PoolMemberNotFoundError < NativeError
    getter member_name : String

    def initialize(@member_name : String, registered : Array(String))
      known = registered.empty? ? "none" : registered.join(", ")
      super(
        "No model named #{@member_name.inspect} in pool (registered: #{known})",
        "pool_member_not_found",
        recoverable: false,
        base_model_loaded: false
      )
    end
  end

  # Holds several named, specialized models resident in parallel - e.g. a
  # small dense model with a domain adapter as a "specialist" plus a larger
  # model as the general chat layer - and routes requests to them by name.
  #
  # The pool owns one MLXRuntime + ModelSession per member. Members are
  # registered eagerly (configuration and adapter paths are validated at
  # `add` time, so bad setups fail fast) but models load **lazily** on first
  # use: each resident model costs real memory, so nothing is paid for a
  # member until a request is actually routed to it. The member's default
  # adapter stack, when configured, is activated automatically right after
  # that first load.
  #
  # The pool is intentionally thin: no queueing, scheduling, or routing
  # policy - the app owns those decisions. Calling into different sessions
  # from different fibers is safe, but generations are serialized by the
  # GPU anyway, so concurrency buys overlap of app work, not parallel
  # token generation.
  #
  # ```crystal
  # pool = Llamero::Native::ModelPool.new
# pool.add("specialist",
#   model_id: "mlx-community/gemma-3-1b-it-4bit",
#   adapters: [{"llamero-docs", Llamero::Storage.adapters_dir.join("llamero-docs").to_s}],
#   default_stack: Llamero::Native::AdapterStack.additive([
  #     Llamero::Native::AdapterSlot.new("llamero-docs"),
  #   ])
  # )
  # pool.add("chat", model_id: "mlx-community/gemma-4-e2b-it-4bit")
  #
  # answer = pool.chat("specialist", [Llamero::Message.user("How do I stream tokens?")])
  # smalltalk = pool.chat("chat", [Llamero::Message.user("Good morning!")])
  # pool.close
  # ```
  class ModelPool
    # One registered model: a runtime plus its lazily created session.
    private class Member
      getter runtime : MLXRuntime
      getter default_stack : AdapterStack?
      getter session : ModelSession?

      def initialize(@runtime : MLXRuntime, @default_stack : AdapterStack?)
      end

      def loaded? : Bool
        @session.try(&.loaded?) || false
      end

      # First use: start the session, load the model, and activate the
      # member's default adapter stack. Subsequent calls reuse the session.
      def ready_session : ModelSession
        existing = @session
        return existing if existing

        session = @runtime.start_session
        session.load_model
        if stack = @default_stack
          session.activate_adapters(stack)
        end
        @session = session
        session
      end
    end

    def initialize(@bridge : Bridge = Bridge.auto)
      @members = {} of String => Member
      @closed = false
    end

    # True when the pool performs real native inference (vs. the mock).
    def real_bridge? : Bool
      @bridge.real?
    end

    def closed? : Bool
      @closed
    end

    # Registers a named member. The runtime is created and `adapters`
    # ({name, path} pairs) are validated and registered immediately, but the
    # model itself does not load until the member is first used.
    #
    # `default_stack` names adapters that must already be in `adapters`;
    # it is auto-activated right after the member's first load.
    def add(
      name : String,
      model_id : String,
      model_path : String? = nil,
      adapters : Array({String, String}) = [] of {String, String},
      default_stack : AdapterStack? = nil,
      cache_limit_bytes : Int | Nil = nil
    ) : Nil
      ensure_open
      raise ArgumentError.new("Pool member name cannot be blank") if name.blank?
      raise ArgumentError.new("Pool already has a member named #{name.inspect}") if @members.has_key?(name)

      runtime = MLXRuntime.new(
        model_id: model_id,
        model_path: model_path,
        cache_limit_bytes: cache_limit_bytes,
        bridge: @bridge
      )
      adapters.each do |adapter_name, adapter_path|
        runtime.adapters.register(adapter_name, adapter_path)
      end

      # Fail at registration time, not first use, when the default stack
      # references an adapter this member does not have.
      if stack = default_stack
        stack.slots.each do |slot|
          unless runtime.adapters.registered?(slot.name)
            raise AdapterNotFoundError.new(
              slot.name,
              "Default stack for pool member #{name.inspect} references unregistered adapter #{slot.name.inspect}"
            )
          end
        end
      end

      @members[name] = Member.new(runtime, default_stack)
    end

    # Returns the member's session, loading the model (and activating the
    # default adapter stack) on first access. Raises PoolMemberNotFoundError
    # for unknown names.
    def [](name : String) : ModelSession
      ensure_open
      member = @members[name]? || raise PoolMemberNotFoundError.new(name, names)
      member.ready_session
    end

    # All registered member names, in registration order.
    def names : Array(String)
      @members.keys
    end

    # Names of members whose model is currently loaded in memory.
    def loaded_names : Array(String)
      @members.compact_map { |name, member| name if member.loaded? }
    end

    def size : Int32
      @members.size
    end

    # Routes a blocking chat to the named member, loading it on first use.
    def chat(
      name : String,
      messages : Array(Message),
      temperature : Float32? = nil,
      max_tokens : Int32? = nil
    ) : NativeChatResponse(Nil)
      self[name].chat(messages, temperature, max_tokens)
    end

    # Routes a structured-output chat to the named member.
    def chat_structured(
      name : String,
      messages : Array(Message),
      response_schema : T.class,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil
    ) : NativeChatResponse(T) forall T
      self[name].chat_structured(messages, response_schema, temperature, max_tokens)
    end

    # Total resident memory across loaded members, from their load metrics.
    # Budgeting is the app's call - the pool only surfaces the number.
    def total_memory_bytes : Int64
      @members.values.sum(0_i64) do |member|
        member.session.try(&.load_metrics).try(&.memory_bytes) || 0_i64
      end
    end

    # Closes every member's runtime (and therefore session). Idempotent.
    def close : Nil
      return if @closed
      @members.each_value do |member|
        member.runtime.close unless member.runtime.closed?
      end
      @closed = true
    end

    private def ensure_open : Nil
      raise SessionStateError.new("Model pool is closed") if @closed
    end
  end
end
