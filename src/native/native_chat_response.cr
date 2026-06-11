require "./metrics"
require "./adapters"

module Llamero::Native
  # Response from a native (on-device) generation. Mirrors ChatResponse(T)
  # but carries native runtime metrics and the adapter stack that was active
  # for the run, so adapter experiments stay traceable.
  class NativeChatResponse(T)
    getter content : String
    getter model_id : String
    getter session_id : String
    getter finish_reason : String
    getter metrics : GenerationMetrics
    getter adapter_stack : AdapterStack
    getter parsed : T?

    def initialize(
      @content : String,
      @model_id : String,
      @session_id : String,
      @metrics : GenerationMetrics = GenerationMetrics.new,
      @adapter_stack : AdapterStack = AdapterStack.none,
      @finish_reason : String = "stop",
      @parsed : T? = nil
    )
    end
  end
end
