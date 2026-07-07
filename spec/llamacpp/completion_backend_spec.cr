require "../spec_helper"

private def runner_with_healthy_probe : Llamero::LlamaCpp::MockRunner
  runner = Llamero::LlamaCpp::MockRunner.new
  runner.enqueue("version: 1 (#{Llamero::LlamaCpp.commit_fragment})")
  runner.enqueue(Llamero::LlamaCpp::SUPPORTED_BUILD[:required_flags].join("\n"))
  runner
end

private def backend_with(runner : Llamero::LlamaCpp::MockRunner, retries : Int32 = 1) : Llamero::LlamaCpp::CompletionBackend
  Llamero::LlamaCpp::CompletionBackend.new(
    model_path: "/models/test.gguf",
    runner: runner,
    grammar_parse_retries: retries
  )
end

private def generation_invocations(runner : Llamero::LlamaCpp::MockRunner)
  runner.invocations.reject { |inv| inv.args == ["--version"] || inv.args == ["--help"] }
end

describe Llamero::LlamaCpp::CompletionBackend do
  describe "generation_mode: :grammar" do
    it "passes the compile-time GBNF via --grammar-file and parses the constrained output" do
      runner = runner_with_healthy_probe
      runner.enqueue(%({"name": "Alice", "age": 30} [end of text]))
      backend = backend_with(runner)

      response = backend.chat_structured(
        [Llamero::Message.user("Give me a person")],
        TestPersonGrammar,
        generation_mode: :grammar
      )

      response.parsed.not_nil!.name.should eq("Alice")
      response.parsed.not_nil!.age.should eq(30)
      response.constraint_backend.should eq("grammar")
      response.attempts.should eq(1)
      response.content.should_not contain("[end of text]")

      generation = generation_invocations(runner).first
      generation.args.should contain("--grammar-file")
      generation.grammar_file_contents.should eq(TestPersonGrammar.to_gbnf)
      generation.args.should contain("-no-cnv")
      generation.args.should contain("--no-display-prompt")
      # structured decoding defaults to temp 0
      generation.args[generation.args.index!("--temp") + 1].should eq("0.0")
      generation.path.should eq(Llamero::LlamaCpp.pinned_binary_path.to_s)
    end

    it "raises GrammarBudgetExceededError for an over-budget type without spawning generation" do
      runner = runner_with_healthy_probe
      backend = backend_with(runner)

      error = expect_raises(Llamero::GrammarBudgetExceededError) do
        backend.chat_structured(
          [Llamero::Message.user("hi")],
          GbnfSpecRecursive,
          generation_mode: :grammar
        )
      end
      error.reason.should contain("recursive type")
      generation_invocations(runner).should be_empty
    end

    it "raises LlamaCppUnavailableError when the pinned binary is missing" do
      runner = Llamero::LlamaCpp::MockRunner.new
      runner.everything_executable = false
      backend = backend_with(runner)

      expect_raises(Llamero::LlamaCppUnavailableError, /requires pinned llama\.cpp/) do
        backend.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :grammar)
      end
    end

    it "retries once on truncated output, on the grammar clock" do
      runner = runner_with_healthy_probe
      runner.enqueue(%({"name": "Ali)) # truncated at max_tokens
      runner.enqueue(%({"name": "Alice", "age": 30}))
      backend = backend_with(runner)

      response = backend.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :grammar)
      response.attempts.should eq(2)
      response.parsed.not_nil!.name.should eq("Alice")
    end

    it "raises an enriched StructuredParseError when retries are exhausted" do
      runner = runner_with_healthy_probe
      runner.enqueue(%({"name": "Ali))
      runner.enqueue(%({"name": "Alic))
      backend = backend_with(runner)

      error = expect_raises(Llamero::Native::StructuredParseError) do
        backend.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :grammar)
      end
      error.generation_mode.should eq("grammar")
      error.backend_name.should eq("llama_cpp_completion")
      error.constraint_backend.should eq("grammar")
      error.grammar_hash.not_nil!.size.should eq(12)
      error.llama_cpp_tag.should eq(Llamero::LlamaCpp::PIN_TAG)
      error.raw_text.should contain("Alic")
    end
  end

  describe "generation_mode: :auto" do
    it "uses grammar when the probe passes and the type is within budget" do
      runner = runner_with_healthy_probe
      runner.enqueue(%({"name": "Bob", "age": 4}))
      backend = backend_with(runner)

      response = backend.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :auto)
      response.constraint_backend.should eq("grammar")
      response.fallback_reason.should be_nil
    end

    it "falls back to schema-prompt with an explicit reason for over-budget types" do
      runner = runner_with_healthy_probe
      runner.enqueue(%({"a": "x"}))
      backend = backend_with(runner)

      response = backend.chat_structured(
        [Llamero::Message.user("hi")],
        GbnfSpecTooManyOptionals,
        generation_mode: :auto
      )

      response.constraint_backend.should eq("schema_prompt")
      response.fallback_reason.not_nil!.should contain("7 optional fields")

      generation = generation_invocations(runner).first
      generation.args.should_not contain("--grammar-file")
      prompt = generation.args[generation.args.index!("-p") + 1]
      prompt.should contain("JSON Schema")
      prompt.should contain("properties")
    end
  end

  describe "generation_mode: :schema_prompt" do
    it "injects the schema into the prompt and does not retry internally" do
      runner = runner_with_healthy_probe
      runner.enqueue("not json at all")
      backend = backend_with(runner)

      error = expect_raises(Llamero::Native::StructuredParseError) do
        backend.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :schema_prompt)
      end
      error.constraint_backend.should eq("schema_prompt")
      generation_invocations(runner).size.should eq(1) # caller-retries contract preserved
    end

    it "parses lenient output (code fences, surrounding prose)" do
      runner = runner_with_healthy_probe
      runner.enqueue("Sure! Here you go:\n```json\n{\"name\": \"Cara\", \"age\": 7}\n```\nHope that helps!")
      backend = backend_with(runner)

      response = backend.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :schema_prompt)
      response.parsed.not_nil!.name.should eq("Cara")
      response.constraint_backend.should eq("schema_prompt")
    end
  end

  describe "capability negotiation" do
    it "advertises GrammarConstrainedOutput only when the probe passes" do
      backend_with(runner_with_healthy_probe).supports?(Llamero::Feature::GrammarConstrainedOutput).should be_true

      missing = Llamero::LlamaCpp::MockRunner.new
      missing.everything_executable = false
      backend_with(missing).supports?(Llamero::Feature::GrammarConstrainedOutput).should be_false
      backend_with(missing).supports?(Llamero::Feature::StructuredOutput).should be_true
    end
  end

  describe "#chat" do
    it "runs an unconstrained completion over the rendered transcript" do
      runner = runner_with_healthy_probe
      runner.enqueue("Hello there [end of text]")
      backend = backend_with(runner)

      response = backend.chat([Llamero::Message.system("Be brief"), Llamero::Message.user("Hi")])
      response.content.should eq("Hello there")

      generation = generation_invocations(runner).first
      prompt = generation.args[generation.args.index!("-p") + 1]
      prompt.should contain("System: Be brief")
      prompt.should contain("User: Hi")
      prompt.should end_with("Assistant:")
    end

    it "scrubs invalid UTF-8 from subprocess output instead of raising from PCRE2" do
      runner = runner_with_healthy_probe
      # "hi " + invalid 3-byte sequence (0xE2 not followed by continuation bytes) + " ok"
      invalid_utf8 = String.new(Bytes[0x68, 0x69, 0x20, 0xE2, 0x28, 0xA1, 0x20, 0x6F, 0x6B])
      invalid_utf8.valid_encoding?.should be_false # guard: fixture really is invalid
      runner.enqueue(invalid_utf8 + " [end of text]")
      backend = backend_with(runner)

      response = backend.chat([Llamero::Message.user("Hi")])
      response.content.valid_encoding?.should be_true
      response.content.should start_with("hi ")
      response.content.should end_with(" ok")
    end
  end
end
