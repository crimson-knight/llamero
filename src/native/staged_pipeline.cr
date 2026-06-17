module Llamero::Native
  # Runs a multi-stage training pipeline with FUSE-FORWARD between stages: each
  # stage trains on the base that has every prior stage fused in, then is itself
  # fused forward. The resident base ends as the fully-composed model. This is
  # the spine for layered experts — e.g. Crystal language -> Amber framework ->
  # product knowledge — and for the canonical unsupervised -> SFT -> RL recipe.
  #
  # ```
  # pipeline = StagedPipeline.new(session, "crystal-expert")
  # pipeline.unsupervised("lang", TrainingDataset.from_documents(doc_paths))
  # pipeline.supervised("usage", TrainingDataset.from_corpus_jsonl(pairs))
  # pipeline.grpo("polish", prompts, reward, rounds: 2)
  # pipeline.run { |i, name| puts "stage #{i}: #{name}" }
  # # resident base is now lang+usage+polish, composed
  # ```
  class StagedPipeline
    # `score` is the optional held-out measurement of the composed model AFTER
    # this stage (nil when no `measure` proc was supplied). `kept` is whether the
    # stage was fused forward; the monotonic guard sets it false for a stage that
    # regressed the measure (it is dropped, not fused).
    record StageResult, name : String, descriptor : AdapterDescriptor, score : Float64? = nil, kept : Bool = true

    getter prefix : String

    @stages = [] of {String, Proc(AdapterDescriptor)}

    def initialize(@session : ModelSession, @prefix : String = "stage")
    end

    # Unsupervised continued-pretraining stage (absorb a domain's knowledge).
    def unsupervised(name : String, dataset : TrainingDataset, config : AdapterTrainingConfig = AdapterTrainingConfig.new) : self
      add(name) { @session.train_adapter(adapter_name(name), dataset, config) }
    end

    # Supervised fine-tuning stage (task format/behavior from examples).
    def supervised(name : String, dataset : TrainingDataset | PreferenceDataset | WeightedDataset, config : AdapterTrainingConfig = AdapterTrainingConfig.new) : self
      add(name) { @session.train_adapter(adapter_name(name), dataset, config) }
    end

    # Reinforcement (GRPO) stage: the bridge drives generate -> reward -> update.
    def grpo(
      name : String, prompts : Array(String), reward : (String, String) -> Float64,
      config : AdapterTrainingConfig = AdapterTrainingConfig.new, rounds : Int32 = 2, samples : Int32 = 6
    ) : self
      add(name) { @session.grpo_train(adapter_name(name), prompts, reward, config: config, rounds: rounds, samples: samples) }
    end

    # A custom stage: the block performs any training and returns its adapter.
    def stage(name : String, &block : -> AdapterDescriptor) : self
      add(name, &block)
    end

    def size : Int32
      @stages.size
    end

    # Runs every stage in order, fusing each forward so the next builds on it.
    # The block is called with (index, name) before each stage. If a `measure`
    # proc is supplied it runs AFTER each stage and its result is recorded on the
    # StageResult — per-stage held-out tracking for the composed model as it grows.
    #
    # With `guard: true` (requires `measure`) the pipeline is MONOTONIC: each
    # stage is fused forward and then the REAL composed model is measured; if it
    # regresses the measure by more than `tolerance` the stage is ROLLED BACK
    # (the base is reloaded and every kept stage's fuse is replayed to reconstruct
    # the composition without it). So the composed model can never end up worse
    # than an earlier stage. Measuring AFTER the fuse — not a live preview — is
    # what catches BOTH a collapsing adapter (a classic GRPO failure on a
    # saturated reward) AND fuse-induced re-quant drift, which a pre-fuse live
    # evaluation cannot see (re-quantization happens during the fuse itself; see
    # development_docs/adapter_composition_experiments.md).
    #
    # The resident base ends as the fully-composed model; call
    # `session.load_model` to reset.
    def run(measure : (-> Float64)? = nil, guard : Bool = false, tolerance : Float64 = 0.0, & : Int32, String ->) : Array(StageResult)
      raise ArgumentError.new("guard: true requires a measure proc") if guard && measure.nil?
      results = [] of StageResult
      kept = [] of AdapterDescriptor
      best = guard ? measure.not_nil!.call : nil
      @stages.each_with_index do |entry, index|
        name, thunk = entry
        yield index, name
        descriptor = thunk.call
        slot_stack = AdapterStack.additive([AdapterSlot.new(descriptor.name)])

        if guard && (m = measure) && (baseline = best)
          # Fuse forward, then measure the real composed model.
          @session.activate_adapters(slot_stack, fuse: true, cumulative: true)
          score = m.call
          if score >= baseline - tolerance
            kept << descriptor
            best = score
            results << StageResult.new(name, descriptor, score, kept: true)
          else
            # Regression (bad adapter or re-quant drift): reconstruct the
            # composition without this stage by reloading and replaying the kept
            # fuses.
            replay(kept)
            results << StageResult.new(name, descriptor, score, kept: false)
          end
        else
          @session.activate_adapters(slot_stack, fuse: true, cumulative: true)
          kept << descriptor
          score = measure.try &.call
          results << StageResult.new(name, descriptor, score, kept: true)
        end
      end
      results
    end

    # Reload the base and replay every kept stage's cumulative fuse, so the
    # resident model becomes exactly the composition of `descriptors` (in order).
    private def replay(descriptors : Array(AdapterDescriptor)) : Nil
      @session.load_model
      descriptors.each do |d|
        @session.activate_adapters(
          AdapterStack.additive([AdapterSlot.new(d.name)]), fuse: true, cumulative: true)
      end
    end

    def run(measure : (-> Float64)? = nil, guard : Bool = false, tolerance : Float64 = 0.0) : Array(StageResult)
      run(measure, guard, tolerance) { }
    end

    private def add(name : String, &block : -> AdapterDescriptor) : self
      @stages << {name, block}
      self
    end

    private def adapter_name(name : String) : String
      "#{@prefix}-#{name}"
    end
  end
end
