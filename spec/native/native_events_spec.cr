require "../spec_helper"

private def frame(payload : String) : Llamero::Native::NativeEvent
  Llamero::Native::NativeEvent.from_bridge_json(payload)
end

describe Llamero::Native::NativeEvent do
  it "parses common fields from every frame" do
    event = frame(%({
      "event": "token_delta", "text": "hi",
      "session_id": "s1", "model_id": "m1",
      "adapter_stack_id": "abc123", "created_at": "2026-06-11T00:00:00Z"
    }))

    event.session_id.should eq("s1")
    event.model_id.should eq("m1")
    event.adapter_stack_id.should eq("abc123")
    event.created_at.year.should eq(2026)
  end

  it "parses model load lifecycle events" do
    frame(%({"event": "model_load_started"})).should be_a(Llamero::Native::ModelLoadStartedEvent)

    progress = frame(%({"event": "model_load_progress", "progress": 0.5, "stage": "weights"}))
    progress.as(Llamero::Native::ModelLoadProgressEvent).progress.should eq(0.5)

    loaded = frame(%({"event": "model_loaded", "model_id": "m1", "load_time_ms": 120.0, "memory_bytes": 1024, "reloaded": false}))
    metrics = loaded.as(Llamero::Native::ModelLoadedEvent).metrics
    metrics.load_time_ms.should eq(120.0)
    metrics.memory_bytes.should eq(1024)
    metrics.reloaded.should be_false
  end

  it "parses adapter activation events" do
    event = frame(%({"event": "adapter_activated", "adapter_names": ["sql", "tone"], "base_model_reloaded": false}))
    activated = event.as(Llamero::Native::AdapterActivatedEvent)

    activated.adapter_names.should eq(["sql", "tone"])
    activated.base_model_reloaded.should be_false
  end

  it "parses generation completion metrics" do
    event = frame(%({
      "event": "generation_completed", "finish_reason": "stop",
      "input_tokens": 12, "output_tokens": 34, "tokens_per_second": 42.5,
      "time_to_first_token_ms": 80.0, "total_time_ms": 900.0
    }))
    completed = event.as(Llamero::Native::GenerationCompletedEvent)

    completed.metrics.input_tokens.should eq(12)
    completed.metrics.output_tokens.should eq(34)
    completed.metrics.tokens_per_second.should eq(42.5)
    completed.metrics.time_to_first_token_ms.should eq(80.0)
    completed.metrics.total_time_ms.should eq(900.0)
    completed.finish_reason.should eq("stop")
  end

  it "parses next-token logit probe comparisons" do
    event = frame(%({
      "event": "logit_probe_completed", "probe_id": "eval-row-1",
      "baseline_captured": false, "input_tokens": 28,
      "baseline_top_token_ids": [1, 2], "baseline_top_tokens": ["A", "B"],
      "baseline_top_logits": [4.0, 3.0],
      "top_token_ids": [3, 1], "top_tokens": ["C", "A"],
      "top_logits": [4.5, 3.1], "mean_absolute_logit_delta": 0.025
    })).as(Llamero::Native::LogitProbeEvent)

    event.probe_id.should eq("eval-row-1")
    event.baseline_captured.should be_false
    event.input_tokens.should eq(28)
    event.baseline_top_tokens.should eq(["A", "B"])
    event.top_tokens.should eq(["C", "A"])
    event.mean_absolute_logit_delta.should eq(0.025)
  end

  it "parses an exact training-tokenizer preview" do
    event = frame(%({
      "event": "training_tokenization_preview_completed", "preview_id": "row-1",
      "rendered_text": "<start_of_turn>model\\nGrant::Base<end_of_turn>",
      "token_count": 4, "token_ids": [1, 2, 3, 4],
      "decoded_text": "<start_of_turn>model\\nGrant::Base<end_of_turn>"
    })).as(Llamero::Native::TrainingTokenizationPreviewEvent)

    event.preview_id.should eq("row-1")
    event.token_count.should eq(4)
    event.token_ids.should eq([1, 2, 3, 4])
    event.decoded_text.should eq("<start_of_turn>model\nGrant::Base<end_of_turn>")
  end

  it "parses training loss probes and the completion-only flag" do
    event = frame(%({
      "event": "training_completed", "adapter_name": "usage",
      "iterations": 400, "final_loss": 1.25,
      "completion_only_loss": false,
      "grant_loss_before": 2.5, "grant_loss_after": 1.75,
      "grant_probe_rows": 84, "total_time_ms": 900.0
    })).as(Llamero::Native::TrainingCompletedEvent)

    event.final_loss.should eq(1.25)
    event.completion_only_loss.should be_false
    event.grant_loss_before.should eq(2.5)
    event.grant_loss_after.should eq(1.75)
    event.grant_probe_rows.should eq(84)
  end

  it "converts error frames into typed errors" do
    event = frame(%({
      "event": "error", "message": "adapter rank mismatch",
      "code": "adapter_incompatible", "recoverable": false, "base_model_loaded": true
    }))
    error_event = event.as(Llamero::Native::NativeErrorEvent)

    error = error_event.to_error
    error.should be_a(Llamero::Native::AdapterIncompatibleError)
    error.base_model_loaded.should be_true
  end

  it "surfaces unrecognized frames as UnknownNativeEvent" do
    frame(%({"event": "something_new", "data": 1})).should be_a(Llamero::Native::UnknownNativeEvent)
    frame(%({"no_event_key": true})).should be_a(Llamero::Native::UnknownNativeEvent)
  end
end
