require "digest/sha256"
require "../clients/base_api_client"
require "../grammars/base_grammar"
require "../grammars/generation_mode"
require "../native/errors"
require "./support"
require "./runner"

module Llamero
  module LlamaCpp
    # Response from the llama.cpp completion backend. `parsed` is the typed
    # result for structured calls; `constraint_backend` records how the output
    # was actually constrained ("grammar" or "schema_prompt"), and `attempts`
    # counts generation attempts (retries happen only in grammar mode, on
    # truncation/subprocess death - grammar output is JSON-valid by
    # construction, so retries are rare by design).
    class CompletionResponse(T)
      getter content : String
      getter parsed : T?
      getter generation_mode : GenerationMode
      getter constraint_backend : String
      getter fallback_reason : String?
      getter attempts : Int32
      getter duration : Time::Span

      def initialize(
        @content : String,
        @generation_mode : GenerationMode,
        @constraint_backend : String,
        @attempts : Int32,
        @duration : Time::Span,
        @parsed : T? = nil,
        @fallback_reason : String? = nil,
      )
      end
    end

    # Local structured generation through the PINNED llama.cpp
    # `llama-completion` binary (subprocess seam, v1: synchronous,
    # non-streaming).
    #
    # The backend never looks at PATH: the binary is always
    # `~/.llamero/llamacpp/<pin>/bin/llama-completion` and the mandatory
    # runtime probe refuses anything that does not report the pinned commit
    # (see LlamaCpp::Probe). Grammar mode writes the compile-time-derived GBNF
    # for T to a tempfile and passes `--grammar-file`.
    #
    # ```crystal
    # backend = Llamero::LlamaCpp::CompletionBackend.new(model_path: "path/to/model.gguf")
    # response = backend.chat_structured([Llamero::Message.user("...")], MySchema)
    # response.parsed          # => MySchema
    # response.constraint_backend # => "grammar"
    # ```
    class CompletionBackend
      DEFAULT_MAX_TOKENS = 1024

      getter model_path : String
      getter grammar_parse_retries : Int32

      def initialize(
        @model_path : String,
        @runner : Runner = SubprocessRunner.new,
        @grammar_parse_retries : Int32 = 1,
        @context_size : Int32? = nil,
        @threads : Int32? = nil,
        @seed : Int32? = nil,
        @timeout : Time::Span = 5.minutes,
      )
        @probe = Probe.new(@runner)
      end

      def backend_name : String
        "llama_cpp_completion"
      end

      def supports?(feature : Feature) : Bool
        case feature
        when .structured_output?           then true
        when .grammar_constrained_output?  then @probe.ok?
        else                                    false
        end
      end

      # Plain (unconstrained) completion over the rendered message transcript.
      def chat(
        messages : Array(Message),
        temperature : Float32? = nil,
        max_tokens : Int32? = nil,
      ) : CompletionResponse(Nil)
        @probe.check!
        result = generate(render_prompt(messages), nil, temperature, max_tokens)
        CompletionResponse(Nil).new(
          content: result[:content],
          generation_mode: GenerationMode::SchemaPrompt,
          constraint_backend: "none",
          attempts: 1,
          duration: result[:duration]
        )
      end

      # Typed structured output.
      #
      # - `:grammar`  - decode-time GBNF constraint; raises if the pinned build
      #   is unavailable (LlamaCppUnavailableError) or T is over the complexity
      #   budget (GrammarBudgetExceededError). Never silently downgrades.
      # - `:schema_prompt` - schema-in-prompt + typed parse (no decode constraint).
      # - `:auto` - grammar when probe + budget allow; otherwise schema-prompt
      #   with an explicit fallback reason and a one-time warning.
      def chat_structured(
        messages : Array(Message),
        response_schema : T.class,
        generation_mode : GenerationMode = Llamero.config.structured_generation_mode,
        temperature : Float32? = nil,
        max_tokens : Int32? = nil,
      ) : CompletionResponse(T) forall T
        case generation_mode
        in .grammar?
          @probe.check!
          grammar = T.to_gbnf?
          if grammar.nil?
            raise GrammarBudgetExceededError.new(T.name, T.gbnf_fallback_reason || "over the GBNF complexity budget")
          end
          grammar_generate(messages, T, grammar, generation_mode, temperature, max_tokens)
        in .schema_prompt?
          @probe.check! # schema-prompt still runs through the pinned binary
          schema_prompt_generate(messages, T, generation_mode, temperature, max_tokens, fallback_reason: nil)
        in .auto?
          probe_failure = @probe.failure_reason
          grammar = probe_failure.nil? ? T.to_gbnf? : nil
          if probe_failure.nil? && grammar
            grammar_generate(messages, T, grammar, generation_mode, temperature, max_tokens)
          else
            reason = probe_failure || T.gbnf_fallback_reason || "grammar unavailable"
            Gbnf.warn_fallback_once(T.name, reason)
            @probe.check! # schema-prompt still needs the pinned binary to run at all
            schema_prompt_generate(messages, T, generation_mode, temperature, max_tokens, fallback_reason: reason)
          end
        end
      end

      private def grammar_generate(
        messages : Array(Message),
        response_schema : T.class,
        grammar : String,
        mode : GenerationMode,
        temperature : Float32?,
        max_tokens : Int32?,
      ) : CompletionResponse(T) forall T
        prompt = render_prompt(messages)
        grammar_hash = Digest::SHA256.hexdigest(grammar)[0, 12]
        attempts = 0
        total_duration = Time::Span.zero
        last_error : Native::StructuredParseError? = nil

        while attempts <= @grammar_parse_retries
          attempts += 1
          result = with_grammar_file(grammar) do |grammar_path|
            generate(prompt, grammar_path, temperature, max_tokens)
          end
          total_duration += result[:duration]
          content = result[:content]

          begin
            parsed = T.from_json(content.strip)
            return CompletionResponse(T).new(
              content: content,
              generation_mode: mode,
              constraint_backend: "grammar",
              attempts: attempts,
              duration: total_duration,
              parsed: parsed
            )
          rescue ex : JSON::ParseException | JSON::SerializableError
            last_error = Native::StructuredParseError.new(
              "Grammar-constrained output failed to parse into #{T.name} (likely truncation at max_tokens): #{ex.message}",
              raw_text: content,
              schema_name: T.name,
              generation_mode: mode.to_s.underscore,
              backend_name: backend_name,
              constraint_backend: "grammar",
              grammar_hash: grammar_hash,
              llama_cpp_tag: PIN_TAG
            )
          end
        end

        raise last_error.not_nil!
      end

      private def schema_prompt_generate(
        messages : Array(Message),
        response_schema : T.class,
        mode : GenerationMode,
        temperature : Float32?,
        max_tokens : Int32?,
        fallback_reason : String?,
      ) : CompletionResponse(T) forall T
        schema_json = T.to_json_schema_string
        instruction = Message.system(
          "You must respond with a single JSON object that conforms to this JSON Schema:\n" \
          "#{schema_json}\n" \
          "Respond with only the JSON object. Do not include code fences, commentary, or any other text."
        )
        prompt = render_prompt([instruction] + messages)
        result = generate(prompt, nil, temperature, max_tokens)
        content = result[:content]

        parsed = begin
          T.from_json(extract_json(content))
        rescue ex : JSON::ParseException | JSON::SerializableError
          raise Native::StructuredParseError.new(
            "Failed to parse model output into #{T.name}: #{ex.message}",
            raw_text: content,
            schema_name: T.name,
            generation_mode: mode.to_s.underscore,
            backend_name: backend_name,
            constraint_backend: "schema_prompt",
            llama_cpp_tag: PIN_TAG,
            fallback_reason: fallback_reason
          )
        end

        CompletionResponse(T).new(
          content: content,
          generation_mode: mode,
          constraint_backend: "schema_prompt",
          attempts: 1,
          duration: result[:duration],
          parsed: parsed,
          fallback_reason: fallback_reason
        )
      end

      private def generate(
        prompt : String,
        grammar_path : String?,
        temperature : Float32?,
        max_tokens : Int32?,
      ) : NamedTuple(content: String, duration: Time::Span)
        args = [
          "-m", @model_path,
          "-no-cnv",
          "--no-display-prompt",
          # Structured extraction defaults to deterministic decoding; pass an
          # explicit temperature to override.
          "--temp", (temperature || 0.0_f32).to_s,
          "-n", (max_tokens || DEFAULT_MAX_TOKENS).to_s,
        ]
        if ctx = @context_size
          args << "--ctx-size" << ctx.to_s
        end
        if threads = @threads
          args << "--threads" << threads.to_s
        end
        if seed = @seed
          args << "--seed" << seed.to_s
        end
        if grammar_path
          args << "--grammar-file" << grammar_path
        end
        args << "-p" << prompt

        result = @runner.run(LlamaCpp.pinned_binary_path, args, timeout: @timeout)
        unless result.exit_code.zero?
          stderr_tail = result.error_output.lines.last(6).join("\n")
          raise LlamaCppProcessError.new(
            "#{SUPPORTED_BUILD[:binary]} exited with #{result.exit_code}.\n#{stderr_tail}"
          )
        end

        {content: strip_end_marker(result.output), duration: result.duration}
      end

      private def with_grammar_file(grammar : String, &)
        file = File.tempfile("llamero-grammar", ".gbnf") do |f|
          f << grammar
        end
        begin
          yield file.path
        ensure
          file.delete rescue nil
        end
      end

      # llama-completion appends " [end of text]" to stdout when generation
      # hits EOS (verified against the pinned build).
      #
      # `scrub` first: subprocess stdout is raw bytes, and an unconstrained
      # model can emit invalid UTF-8 (e.g. a multi-byte codepoint truncated at
      # the max_tokens boundary). PCRE2 raises ArgumentError on invalid UTF-8,
      # which would crash the caller instead of returning content that simply
      # fails the typed parse (observed live: SmolLM-135M rambling at temp 0.8
      # killed a benchmark run mid-flight).
      private def strip_end_marker(output : String) : String
        output.scrub.gsub(/\s*\[end of text\]\s*\z/, "").strip
      end

      # v1 prompt rendering is a plain role-labelled transcript (no model chat
      # template). Grammar mode makes the response shape independent of the
      # template; schema-prompt quality on chat-tuned models can improve later
      # without changing this API.
      private def render_prompt(messages : Array(Message)) : String
        parts = messages.map do |message|
          case message.role
          when .system?    then "System: #{message.content}"
          when .user?      then "User: #{message.content}"
          when .assistant? then "Assistant: #{message.content}"
          else                  "#{message.role}: #{message.content}"
          end
        end
        parts.join("\n\n") + "\n\nAssistant:"
      end

      # Same lenient extraction the native MLX schema-prompt path uses.
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
    end
  end

  # The pinned binary started but exited non-zero.
  class LlamaCppProcessError < Exception
  end
end
