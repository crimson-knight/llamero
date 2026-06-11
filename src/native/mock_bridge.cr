require "json"
require "./bridge"

module Llamero::Native
  # Deterministic in-process bridge used for specs and non-Apple development.
  #
  # Behavior is fully predictable: fixed metrics, fixed default response
  # text, and explicit failure knobs. Specs can script exact responses and
  # inspect per-session state (load counts, active adapters) to verify the
  # "no base model reload on adapter change" invariant.
  #
  # ```crystal
  # bridge = Llamero::Native::MockBridge.new
  # bridge.scripted_responses << %({"name":"Ada","age":36})
  # runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: bridge)
  # ```
  class MockBridge < Bridge
    # Deterministic metrics every mock load/generation reports.
    LOAD_TIME_MS    = 120.0
    MEMORY_BYTES    = 512_i64 * 1024 * 1024
    TOKENS_PER_SEC  =  42.0
    TTFT_MS         =   5.0
    TOTAL_TIME_MS   = 100.0

    private class SessionState
      property runtime_handle : Int64
      property model_id : String
      property loaded = false
      property load_count = 0
      property active_adapter_names = [] of String
      property adapter_stack_id = "base"

      def initialize(@runtime_handle : Int64, @model_id : String)
      end
    end

    # Queue of canned response texts; each generation shifts one off. When
    # empty, a deterministic default response is generated instead.
    getter scripted_responses = [] of String

    # Failure knobs: set to true to make the next matching call emit an
    # error event (the knob resets automatically).
    property fail_next_model_load = false
    property fail_next_adapter_activation = false
    property fail_next_generation = false
    property fail_next_training = false

    def initialize
      @next_handle = 1_i64
      @runtime_configs = {} of Int64 => JSON::Any
      @sessions = {} of Int64 => SessionState
    end

    def name : String
      "mock"
    end

    def real? : Bool
      false
    end

    def create_runtime(config_json : String) : Int64
      handle = next_handle
      @runtime_configs[handle] = JSON.parse(config_json)
      handle
    end

    def free_runtime(runtime : Int64) : Nil
      @runtime_configs.delete(runtime)
    end

    def create_session(runtime : Int64) : Int64
      config = @runtime_configs[runtime]? || raise BridgeUnavailableError.new("Unknown runtime handle: #{runtime}")
      handle = next_handle
      model_id = config["model_id"]?.try(&.as_s) || "mock-model"
      @sessions[handle] = SessionState.new(runtime, model_id)
      handle
    end

    def free_session(session : Int64) : Nil
      @sessions.delete(session)
    end

    def load_model(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      state = session_state(session)

      if @fail_next_model_load
        @fail_next_model_load = false
        emit(on_event, state, session, {
          "event" => "error", "message" => "Mock model load failure",
          "code" => "model_load_failed", "recoverable" => true, "base_model_loaded" => false,
        })
        return
      end

      emit(on_event, state, session, {"event" => "model_load_started"})
      emit(on_event, state, session, {"event" => "model_load_progress", "progress" => 0.5, "stage" => "weights"})
      emit(on_event, state, session, {"event" => "model_load_progress", "progress" => 1.0, "stage" => "warmup"})

      reloaded = state.loaded
      state.loaded = true
      state.load_count += 1

      emit(on_event, state, session, {
        "event" => "model_loaded", "load_time_ms" => LOAD_TIME_MS,
        "memory_bytes" => MEMORY_BYTES, "reloaded" => reloaded,
      })
    end

    def activate_adapters(session : Int64, stack_json : String, &on_event : JSON::Any ->) : Nil
      state = session_state(session)

      if @fail_next_adapter_activation
        @fail_next_adapter_activation = false
        emit(on_event, state, session, {
          "event" => "error", "message" => "Mock adapter activation failure",
          "code" => "adapter_activation_failed", "recoverable" => true, "base_model_loaded" => state.loaded,
        })
        return
      end

      stack = JSON.parse(stack_json)
      names = stack["slots"]?.try(&.as_a.map { |slot| slot["name"].as_s }) || [] of String
      state.active_adapter_names = names
      state.adapter_stack_id = stack["stack_id"]?.try(&.as_s) || "base"

      emit(on_event, state, session, {
        "event" => "adapter_activated",
        "adapter_names" => names,
        "base_model_reloaded" => false,
      })
    end

    def generate(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      state = session_state(session)

      if @fail_next_generation
        @fail_next_generation = false
        emit(on_event, state, session, {
          "event" => "error", "message" => "Mock generation failure",
          "code" => "generation_failed", "recoverable" => true, "base_model_loaded" => state.loaded,
        })
        return
      end

      request = JSON.parse(request_json)
      structured = request["structured"]?.try(&.as_bool) || false
      delta_event = structured ? "structured_json_delta" : "token_delta"

      text = @scripted_responses.shift? || default_response(state)
      chunks = chunk_text(text)
      chunks.each do |chunk|
        emit(on_event, state, session, {"event" => delta_event, "text" => chunk})
      end

      input_tokens = (request["messages"]?.try(&.as_a.sum { |m| m["content"].as_s.split.size }) || 0).to_i

      emit(on_event, state, session, {
        "event" => "generation_completed", "finish_reason" => "stop",
        "input_tokens" => input_tokens, "output_tokens" => chunks.size,
        "tokens_per_second" => TOKENS_PER_SEC, "time_to_first_token_ms" => TTFT_MS,
        "total_time_ms" => TOTAL_TIME_MS,
      })
    end

    def train_adapter(session : Int64, request_json : String, &on_event : JSON::Any ->) : Nil
      state = session_state(session)

      if @fail_next_training
        @fail_next_training = false
        emit(on_event, state, session, {
          "event" => "error", "message" => "Mock training failure",
          "code" => "adapter_training_failed", "recoverable" => true, "base_model_loaded" => state.loaded,
        })
        return
      end

      request = JSON.parse(request_json)
      name = request["name"]?.try(&.as_s) || "adapter"
      output_dir = request["output_dir"].as_s
      iterations = request["iterations"]?.try(&.as_i) || 200
      steps_per_report = request["steps_per_report"]?.try(&.as_i) || 10

      # Deterministic decreasing loss curve.
      loss = 3.0
      step = steps_per_report
      while step <= iterations
        loss *= 0.9
        emit(on_event, state, session, {
          "event" => "training_progress", "adapter_name" => name,
          "iteration" => step, "total_iterations" => iterations,
          "loss" => loss.round(4), "iterations_per_second" => 5.0, "tokens_per_second" => 250.0,
        })
        step += steps_per_report
      end

      emit(on_event, state, session, {
        "event" => "training_validation", "adapter_name" => name,
        "iteration" => iterations, "validation_loss" => (loss + 0.05).round(4),
      })

      # Write a real artifact in the mlx_lm adapter layout so the registry's
      # validation and checksumming work against mock-trained adapters.
      Dir.mkdir_p(output_dir)
      File.write(File.join(output_dir, "adapters.safetensors"), "mock-trained-weights-#{name}")
      File.write(File.join(output_dir, "adapter_config.json"), {
        "num_layers"      => request["num_layers"]?.try(&.as_i) || 16,
        "fine_tune_type"  => request["fine_tune_type"]?.try(&.as_s) || "lora",
        "lora_parameters" => {
          "rank"  => request["rank"]?.try(&.as_i) || 8,
          "scale" => request["scale"]?.try(&.as_f) || 10.0,
        },
      }.to_json)

      emit(on_event, state, session, {
        "event" => "training_completed", "adapter_name" => name,
        "adapter_path" => output_dir, "iterations" => iterations,
        "final_loss" => loss.round(4), "final_validation_loss" => (loss + 0.05).round(4),
        "total_time_ms" => 1000.0,
      })
    end

    # Spec helpers: inspect per-session state without going through events.

    def load_count(session : Int64) : Int32
      session_state(session).load_count
    end

    def loaded?(session : Int64) : Bool
      session_state(session).loaded
    end

    def active_adapters(session : Int64) : Array(String)
      session_state(session).active_adapter_names
    end

    private def session_state(session : Int64) : SessionState
      @sessions[session]? || raise BridgeUnavailableError.new("Unknown session handle: #{session}")
    end

    private def next_handle : Int64
      handle = @next_handle
      @next_handle += 1
      handle
    end

    private def default_response(state : SessionState) : String
      if state.active_adapter_names.empty?
        "mock response from #{state.model_id}"
      else
        "mock response from #{state.model_id} with adapters #{state.active_adapter_names.join(",")}"
      end
    end

    # Splits text into small deterministic chunks so streaming consumers see
    # multiple deltas, like a real token stream would produce.
    private def chunk_text(text : String) : Array(String)
      chunks = [] of String
      slice_size = 8
      offset = 0
      while offset < text.size
        chunks << text[offset, slice_size]
        offset += slice_size
      end
      chunks
    end

    private def emit(on_event : JSON::Any ->, state : SessionState, session : Int64, payload) : Nil
      frame = {
        "session_id"       => "mock-session-#{session}",
        "model_id"         => state.model_id,
        "adapter_stack_id" => state.adapter_stack_id,
        "created_at"       => Time.utc.to_rfc3339,
      }.merge(payload)
      on_event.call(JSON.parse(frame.to_json))
    end
  end
end
