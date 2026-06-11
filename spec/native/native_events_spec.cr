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
