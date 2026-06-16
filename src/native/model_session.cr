require "json"
require "../clients/base_api_client"
require "../config/storage"
require "../grammars/base_grammar"
require "./bridge"
require "./events"
require "./adapters"
require "./model_downloader"
require "./native_chat_response"
require "./training"

module Llamero::Native
  # One loaded model context on a native bridge.
  #
  # A session loads its base model once and keeps it resident. Adapter
  # stacks can then be activated and deactivated without reloading the
  # model - that is the core invariant of the native track, and `load_count`
  # plus `base_model_reloaded?` make violations visible.
  #
  # ```
  # session = runtime.start_session
  # session.load_model
  #
  # session.chat_stream([Llamero::Message.user("Hello!")]) do |chunk|
  #   print chunk
  # end
  #
  # session.activate_adapters(stack)
  # response = session.chat_structured([Llamero::Message.user("...")], MySchema)
  # ```
  class ModelSession
    enum State
      Unloaded
      Loading
      Loaded
      Failed
      Closed
    end

    getter state : State = State::Unloaded
    getter model_id : String
    getter active_adapter_stack : AdapterStack
    getter load_metrics : ModelLoadMetrics?
    getter last_generation_metrics : GenerationMetrics?

    # Number of times the base model has been loaded into memory. Adapter
    # activations must not increase this.
    getter load_count : Int32 = 0

    # Whether the most recent adapter activation forced a base model reload.
    # The target behavior is false; bridges report it honestly when not.
    getter? base_model_reloaded : Bool = false

    # Whether the active adapter was FUSED into the base weights (mutating and
    # re-quantizing them) rather than installed as live LoRA layers. A fused
    # delta cannot be cheaply unloaded, so the next activate/deactivate reloads
    # the base for a clean slate. See `activate_adapters(stack, fuse: true)`.
    getter? active_adapters_fused : Bool = false

    # Session id assigned by the bridge (populated from the first event).
    getter session_id : String = ""

    def initialize(
      @bridge : Bridge,
      @handle : Int64,
      @model_id : String,
      @registry : AdapterRegistry,
      @model_path : String? = nil,
      @downloader : ModelDownloader? = nil,
    )
      @active_adapter_stack = AdapterStack.none
      @event_listeners = [] of NativeEvent ->
    end

    # Registers a listener for every typed event this session produces.
    # Useful for UIs, tracing, and metrics collection.
    def on_event(&block : NativeEvent ->) : Nil
      @event_listeners << block
    end

    def loaded? : Bool
      @state.loaded?
    end

    def closed? : Bool
      @state.closed?
    end

    # Loads the base model into memory. Idempotent guard: raises if called
    # on a closed session; loading an already-loaded session reloads and
    # increments load_count (bridges report `reloaded: true`).
    def load_model : ModelLoadMetrics
      ensure_open
      @state = State::Loading

      request_json = begin
        build_load_request
      rescue ex
        @state = State::Failed
        raise ex
      end

      error : NativeErrorEvent? = nil
      metrics : ModelLoadMetrics? = nil

      @bridge.load_model(@handle, request_json) do |frame|
        event = dispatch(frame)
        case event
        when ModelLoadedEvent then metrics = event.metrics
        when NativeErrorEvent then error = event
        end
      end

      if failure = error
        @state = failure.base_model_loaded ? State::Loaded : State::Failed
        raise failure.to_error
      end

      final_metrics = metrics
      loaded = final_metrics || raise ModelLoadError.new("Bridge completed load without a model_loaded event")
      @state = State::Loaded
      @load_count += 1
      @load_metrics = loaded
      loaded
    end

    # Applies an adapter stack to the resident model. Names are resolved
    # through the adapter registry before the bridge is touched, so unknown
    # adapters fail fast without disturbing the session. Adapter errors from
    # the bridge are raised but never kill the resident model session.
    #
    # With `fuse: true` the adapter delta is baked into the (re-quantized) base
    # weights instead of installed as live LoRA layers: generation then runs at
    # full base throughput (no per-token LoRA ops) at the cost of mutating the
    # resident base. Because a fused delta cannot be unloaded, the next
    # activate/deactivate transparently reloads the base first (load_count then
    # increments). Use it for a single adapter held for a session; keep the
    # default (`fuse: false`) when you need cheap hot-swapping.
    # `cumulative: true` (with `fuse: true`) bakes the adapter PERMANENTLY into
    # the base for fuse-forward staging: the next `train_adapter` trains on top of
    # it (so you can stack Crystal -> Amber -> product knowledge by fusing each
    # stage forward). The base stays mutated until you `load_model` to reset.
    def activate_adapters(stack : AdapterStack, fuse : Bool = false, cumulative : Bool = false) : Nil
      ensure_loaded

      # A previously (non-cumulatively) fused adapter is baked into the resident
      # weights and cannot be unloaded; reload the base before any new stack.
      if active_adapters_fused?
        load_model
        @active_adapters_fused = false
        @active_adapter_stack = AdapterStack.none
      end

      resolved = @registry.resolve(stack)

      error : NativeErrorEvent? = nil
      reloaded = false
      fused = false
      cumulative_fused = false

      @bridge.activate_adapters(@handle, bridge_stack_json(stack, resolved, fuse, cumulative)) do |frame|
        event = dispatch(frame)
        case event
        when AdapterActivatedEvent
          reloaded = event.base_model_reloaded
          fused = event.fused
          cumulative_fused = event.cumulative
        when NativeErrorEvent
          error = event
        end
      end

      if failure = error
        raise failure.to_error
      end

      # A cumulative fuse leaves no live adapter (baked into the base): no stack
      # is "active", and there's nothing to reload-away (the next stage trains on
      # the fused base; load_model resets to the original).
      @active_adapter_stack = cumulative_fused ? AdapterStack.none : stack
      @active_adapters_fused = fused && !cumulative_fused
      @base_model_reloaded = reloaded
    end

    # Returns the session to base-model-only generation.
    def deactivate_adapters : Nil
      activate_adapters(AdapterStack.none)
    end

    # Summary of the most recent adapter training run on this session.
    getter last_training : TrainingCompletedEvent?

    # Trains a new LoRA/DoRA adapter on the resident model and registers the
    # resulting artifact under `name`, ready for activate_adapters.
    #
    # The dataset is either a TrainingDataset (written to
    # `<output_dir>/dataset/`) or a directory already containing
    # `train.jsonl` (and optionally `valid.jsonl`) in mlx_lm format.
    # `output_dir` defaults to the configured adapter storage directory.
    #
    # Datasets that kept the default format are automatically rendered
    # through the model's own chat template (TrainingDataset.template_from)
    # when the model directory is available locally, so training matches
    # inference rendering exactly; the built-in `template_for` templates are
    # the fallback. Check `dataset.template_source` afterwards to see which
    # template was used ("model-chat-template" or "built-in"). Passing
    # `format:` when building the dataset skips the auto-template entirely.
    #
    # Training streams TrainingProgressEvent / TrainingValidationEvent to
    # event listeners (and the optional block), so apps can show loss curves
    # live. The base model is restored when training finishes or fails -
    # the resident session keeps working either way, and the trained adapter
    # only affects generation once explicitly activated.
    #
    # ```
    # descriptor = session.train_adapter("lx900-manual", dataset)
    # session.activate_adapters(
    #   AdapterStack.additive([AdapterSlot.new("lx900-manual")])
    # )
    # ```
    def train_adapter(
      name : String,
      dataset : TrainingDataset | PreferenceDataset | WeightedDataset | Path | String,
      config : AdapterTrainingConfig = AdapterTrainingConfig.new,
      output_dir : Path | String | Nil = nil,
      &progress : TrainingProgressEvent -> Nil
    ) : AdapterDescriptor
      ensure_loaded
      raise ArgumentError.new("Adapter name cannot be blank") if name.blank?
      config.validate!

      adapter_dir = Path[output_dir || Llamero::Storage.adapters_dir.join(name)].expand

      # PreferenceDataset/WeightedDataset select the DPO/weighted bridge paths.
      data_dir = case dataset
                 in TrainingDataset
                   apply_model_template(dataset)
                   dataset.write(adapter_dir.join("dataset"))
                 in PreferenceDataset
                   config.training_method = :dpo
                   dataset.write(adapter_dir.join("dataset"))
                 in WeightedDataset
                   config.training_method = :weighted
                   dataset.write(adapter_dir.join("dataset"))
                 in Path, String
                   dir = Path[dataset].expand
                   unless File.exists?(dir.join("train.jsonl")) || File.exists?(dir.join("train.txt"))
                     raise ArgumentError.new("Dataset directory #{dir} has no train.jsonl or train.txt")
                   end
                   dir
                 end

      error : NativeErrorEvent? = nil
      completed : TrainingCompletedEvent? = nil

      @bridge.train_adapter(@handle, training_request_json(name, data_dir, adapter_dir, config)) do |frame|
        event = dispatch(frame)
        case event
        when TrainingProgressEvent  then progress.call(event)
        when TrainingCompletedEvent then completed = event
        when NativeErrorEvent       then error = event
        end
      end

      if failure = error
        raise failure.to_error
      end

      final_completed = completed
      summary = final_completed || raise AdapterTrainingError.new("Bridge finished training without a training_completed event")
      @last_training = summary
      @registry.register(name, summary.adapter_path)
    end

    def train_adapter(
      name : String,
      dataset : TrainingDataset | PreferenceDataset | WeightedDataset | Path | String,
      config : AdapterTrainingConfig = AdapterTrainingConfig.new,
      output_dir : Path | String | Nil = nil,
    ) : AdapterDescriptor
      train_adapter(name, dataset, config, output_dir) { }
    end

    # Bridge-driven GRPO: the bridge itself samples `samples` completions per
    # prompt, calls `reward.call(prompt, completion)` for each (on this thread),
    # computes group-relative advantages, and runs the KL-anchored weighted
    # update for `rounds` rounds — then saves and registers the adapter. The
    # whole reinforcement loop runs in one call; only the reward comes from
    # Crystal. `reward` is typically a `Rubric`'s score.
    def grpo_train(
      name : String,
      prompts : Array(String),
      reward : (String, String) -> Float64,
      config : AdapterTrainingConfig = AdapterTrainingConfig.new,
      rounds : Int32 = 2,
      samples : Int32 = 6,
      temperature : Float32 = 0.9_f32,
      max_tokens : Int32 = 64,
      output_dir : Path | String | Nil = nil,
    ) : AdapterDescriptor
      ensure_loaded
      raise ArgumentError.new("Adapter name cannot be blank") if name.blank?
      raise ArgumentError.new("prompts cannot be empty") if prompts.empty?
      config.validate!

      adapter_dir = Path[output_dir || Llamero::Storage.adapters_dir.join(name)].expand
      request = grpo_request_json(name, adapter_dir, prompts, config, rounds, samples, temperature, max_tokens)

      error : NativeErrorEvent? = nil
      completed : TrainingCompletedEvent? = nil
      @bridge.grpo_loop(@handle, request, reward) do |frame|
        event = dispatch(frame)
        case event
        when TrainingCompletedEvent then completed = event
        when NativeErrorEvent       then error = event
        end
      end

      if failure = error
        raise failure.to_error
      end
      final_completed = completed
      summary = final_completed || raise AdapterTrainingError.new("Bridge finished GRPO without a training_completed event")
      @last_training = summary
      @registry.register(name, summary.adapter_path)
    end

    private def grpo_request_json(
      name : String, output_dir : Path, prompts : Array(String),
      config : AdapterTrainingConfig, rounds : Int32, samples : Int32,
      temperature : Float32, max_tokens : Int32
    ) : String
      JSON.build do |json|
        json.object do
          json.field "name", name
          json.field "output_dir", output_dir.to_s
          json.field "rank", config.rank
          json.field "scale", config.scale
          json.field "num_layers", config.num_layers
          json.field "rounds", rounds
          json.field "samples", samples
          json.field "temperature", temperature
          json.field "max_tokens", max_tokens
          json.field "iterations", config.iterations
          json.field "learning_rate", config.learning_rate
          json.field "kl_beta", config.kl_beta
          json.field "prompts" do
            json.array { prompts.each { |p| json.string(p) } }
          end
        end
      end
    end

    # Blocking chat completion against the resident model.
    def chat(
      messages : Array(Message),
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
    ) : NativeChatResponse(Nil)
      chat_stream(messages, temperature, max_tokens) { }
    end

    # Streaming chat completion. Token deltas are yielded as they arrive and
    # the full response (with metrics) is returned at the end.
    def chat_stream(
      messages : Array(Message),
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
      &block : String -> Nil
    ) : NativeChatResponse(Nil)
      ensure_loaded
      request = build_request(messages, temperature, max_tokens, structured: false)
      content, metrics, finish_reason = run_generation(request) do |delta|
        block.call(delta)
      end

      NativeChatResponse(Nil).new(
        content: content,
        model_id: @model_id,
        session_id: @session_id,
        metrics: metrics,
        adapter_stack: @active_adapter_stack,
        finish_reason: finish_reason
      )
    end

    # Structured output against the resident model.
    #
    # The schema is generated Crystal-side (see Llamero::BaseGrammar), the
    # prompt instructs the model to emit conforming JSON, and the accumulated
    # stream is parsed into the schema class. The schema also rides along in
    # the bridge request so grammar-constrained decoding can use it once the
    # native bridge supports logit masking.
    #
    # Parse failures raise StructuredParseError carrying the raw text, the
    # schema name, and the active adapter stack. Retries can run without
    # reloading the base model.
    def chat_structured(
      messages : Array(Message),
      response_schema : T.class,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
    ) : NativeChatResponse(T) forall T
      ensure_loaded
      schema_json = T.to_json_schema_string
      prompted = inject_schema_instruction(messages, schema_json)
      request = build_request(prompted, temperature, max_tokens, structured: true, schema_json: schema_json)

      content, metrics, finish_reason = run_generation(request) { }

      json_text = extract_json(content)
      parsed = begin
        T.from_json(json_text)
      rescue ex : JSON::ParseException | JSON::SerializableError
        raise StructuredParseError.new(
          "Failed to parse model output into #{T.name}: #{ex.message}",
          raw_text: content,
          schema_name: T.name,
          adapter_stack: @active_adapter_stack
        )
      end

      NativeChatResponse(T).new(
        content: content,
        model_id: @model_id,
        session_id: @session_id,
        metrics: metrics,
        adapter_stack: @active_adapter_stack,
        finish_reason: finish_reason,
        parsed: parsed
      )
    end

    # Frees the bridge-side session. The session cannot be used afterwards.
    def close : Nil
      return if closed?
      @bridge.free_session(@handle)
      @state = State::Closed
    end

    # Resolves the model to a local directory for the bridge. Explicit
    # model_path wins; otherwise a real bridge gets the model downloaded
    # Crystal-side (with download progress surfaced as
    # ModelLoadProgressEvent), and the mock bridge needs no path at all.
    private def build_load_request : String
      path = @model_path
      if path.nil? && @bridge.real?
        downloader = @downloader || ModelDownloader.new
        last_reported = -1.0
        path = downloader.resolve(@model_id) do |fraction|
          # Throttle synthetic progress frames to whole-percent steps.
          next if (fraction - last_reported) < 0.01 && fraction < 1.0
          last_reported = fraction
          dispatch(JSON.parse({
            "event"            => "model_load_progress",
            "session_id"       => @session_id,
            "model_id"         => @model_id,
            "adapter_stack_id" => @active_adapter_stack.stack_id,
            "created_at"       => Time.utc.to_rfc3339,
            "progress"         => fraction,
            "stage"            => "download",
          }.to_json))
        end.to_s
      end

      JSON.build do |json|
        json.object do
          json.field "model_path", path if path
        end
      end
    end

    private def run_generation(request_json : String, &on_delta : String ->) : {String, GenerationMetrics, String}
      content = String::Builder.new
      metrics = GenerationMetrics.new
      finish_reason = "stop"
      error : NativeErrorEvent? = nil

      @bridge.generate(@handle, request_json) do |frame|
        event = dispatch(frame)
        case event
        when TokenDeltaEvent
          content << event.text
          on_delta.call(event.text)
        when StructuredJsonDeltaEvent
          content << event.text
          on_delta.call(event.text)
        when GenerationCompletedEvent
          metrics = event.metrics
          finish_reason = event.finish_reason
        when NativeErrorEvent
          error = event
        end
      end

      if failure = error
        raise failure.to_error
      end

      @last_generation_metrics = metrics
      {content.to_s, metrics, finish_reason}
    end

    # Parses a bridge frame, captures the session id, fans out to listeners,
    # and returns the typed event for the caller's own handling.
    private def dispatch(frame : JSON::Any) : NativeEvent
      event = NativeEvent.from_bridge_json(frame)
      @session_id = event.session_id unless event.session_id.empty?
      @event_listeners.each(&.call(event))
      event
    end

    private def build_request(
      messages : Array(Message),
      temperature : Float32?,
      max_tokens : Int32?,
      structured : Bool,
      schema_json : String? = nil,
    ) : String
      JSON.build do |json|
        json.object do
          json.field "messages" do
            json.array do
              messages.each do |message|
                json.object do
                  json.field "role", message.role.to_s.downcase
                  json.field "content", message.content
                end
              end
            end
          end
          json.field "temperature", temperature if temperature
          json.field "max_tokens", max_tokens if max_tokens
          json.field "structured", structured
          if schema_json
            json.field "schema" do
              json.raw schema_json
            end
          end
        end
      end
    end

    # Auto-template path for train_adapter: datasets without an explicit
    # format render through the model's own chat template when it is on
    # disk, else through the built-in template for the model family. Either
    # way the choice lands in dataset.template_source.
    private def apply_model_template(dataset : TrainingDataset) : Nil
      return if dataset.format_explicit?

      model_template = local_model_dir.try { |dir| TrainingDataset.template_from(dir) }
      if model_template
        dataset.use_template(model_template, "model-chat-template")
      else
        dataset.use_template(TrainingDataset.template_for(@model_id), "built-in")
      end
    end

    # The model's local directory, when one exists: an explicit model_path
    # wins, else the downloader cache location for the model id. Never
    # triggers a download.
    private def local_model_dir : Path?
      if path = @model_path
        dir = Path[path].expand
        return File.directory?(dir) ? dir : nil
      end

      downloader = @downloader || ModelDownloader.new
      dir = downloader.model_dir(@model_id)
      File.directory?(dir) ? dir : nil
    end

    private def training_request_json(name : String, data_dir : Path, output_dir : Path, config : AdapterTrainingConfig) : String
      JSON.build do |json|
        json.object do
          json.field "name", name
          json.field "data_dir", data_dir.to_s
          json.field "output_dir", output_dir.to_s
          json.field "rank", config.rank
          json.field "scale", config.scale
          json.field "num_layers", config.num_layers
          json.field "fine_tune_type", config.fine_tune_type.to_s.downcase
          json.field "iterations", config.iterations
          json.field "batch_size", config.batch_size
          json.field "learning_rate", config.learning_rate
          json.field "steps_per_report", config.steps_per_report
          json.field "steps_per_eval", config.steps_per_eval
          json.field "validation_batches", config.validation_batches
          json.field "method", config.training_method.to_s
          json.field "dpo_beta", config.dpo_beta
          json.field "kl_beta", config.kl_beta
        end
      end
    end

    private def bridge_stack_json(stack : AdapterStack, resolved : Array({AdapterSlot, AdapterDescriptor}), fuse : Bool, cumulative : Bool = false) : String
      JSON.build do |json|
        json.object do
          json.field "stack_id", stack.stack_id
          json.field "mode", stack.mode.to_s.downcase
          json.field "fuse", fuse
          json.field "cumulative", cumulative
          json.field "slots" do
            json.array do
              resolved.each do |slot, descriptor|
                json.object do
                  json.field "name", slot.name
                  json.field "scale", slot.scale
                  json.field "path", descriptor.path
                  json.field "checksum", descriptor.checksum
                end
              end
            end
          end
        end
      end
    end

    private def inject_schema_instruction(messages : Array(Message), schema_json : String) : Array(Message)
      instruction = Message.system(
        "You must respond with a single JSON object that conforms to this JSON Schema:\n" \
        "#{schema_json}\n" \
        "Respond with only the JSON object. Do not include code fences, commentary, or any other text."
      )
      [instruction] + messages
    end

    # Pulls the JSON object out of model output that may include code fences
    # or surrounding prose.
    private def extract_json(content : String) : String
      text = content.strip
      if fenced = text.match(/```(?:json)?\s*(.+?)```/m)
        text = fenced[1].strip
      end
      start_index = text.index('{')
      end_index = text.rindex('}')
      if start_index && end_index && end_index > start_index
        text[start_index..end_index]
      else
        text
      end
    end

    private def ensure_open : Nil
      raise SessionStateError.new("Session is closed") if closed?
    end

    private def ensure_loaded : Nil
      ensure_open
      unless loaded?
        raise SessionStateError.new("Model is not loaded; call load_model first (state: #{@state})")
      end
    end
  end
end
