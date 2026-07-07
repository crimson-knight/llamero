require "../spec_helper"

private def mock_session(scripted : String? = nil)
  bridge = Llamero::Native::MockBridge.new
  bridge.scripted_responses << scripted if scripted
  runtime = Llamero::Native::MLXRuntime.new(model_id: "test-model", bridge: bridge)
  session = runtime.start_session
  session.load_model
  session
end

describe "generation_mode negotiation across backends" do
  describe "native MLX session" do
    it "keeps :auto on the honest schema-prompt flow (existing behavior)" do
      session = mock_session(%({"name": "Ada", "age": 36}))
      response = session.chat_structured(
        [Llamero::Message.user("Who?")],
        TestPersonGrammar,
        generation_mode: :auto
      )
      response.parsed.should_not be_nil
    end

    it "raises on forced :grammar instead of silently downgrading" do
      session = mock_session
      error = expect_raises(Llamero::UnsupportedGenerationModeError) do
        session.chat_structured([Llamero::Message.user("Who?")], TestPersonGrammar, generation_mode: :grammar)
      end
      error.backend_name.should eq("native_mlx")
      error.message.not_nil!.should contain("drops the schema field")
    end
  end

  describe "cloud clients" do
    it "raises on forced :grammar before any HTTP request" do
      client = Llamero::OpenAIClient.new(api_key: "test-key")
      # No WebMock stub: proof the request is never attempted.
      expect_raises(Llamero::UnsupportedGenerationModeError, /native structured-output modes/) do
        client.chat_structured(
          [Llamero::Message.user("hi")],
          TestPersonGrammar,
          generation_mode: :grammar
        )
      end
    end

    it "does not advertise GrammarConstrainedOutput" do
      client = Llamero::OpenAIClient.new(api_key: "test-key")
      client.supports?(Llamero::Feature::GrammarConstrainedOutput).should be_false
      client.supports?(Llamero::Feature::StructuredOutput).should be_true
    end

    it "propagates the raise through Client failover (no silent downgrade to a fallback provider)" do
      client = TestHelpers.create_test_client(:openai, [:anthropic])
      expect_raises(Llamero::UnsupportedGenerationModeError) do
        client.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :grammar)
      end
    end

    it "keeps :auto exactly on today's native schema path" do
      TestHelpers.stub_openai_success(%({"name": "Cloud", "age": 1}))
      client = Llamero::OpenAIClient.new(api_key: "test-key")
      response = client.chat_structured([Llamero::Message.user("hi")], TestPersonGrammar, generation_mode: :auto)
      response.parsed.not_nil!.name.should eq("Cloud")
    end
  end

  describe "global default" do
    it "defaults chat_structured's generation_mode to Llamero.config.structured_generation_mode (:auto)" do
      Llamero.config.structured_generation_mode.should eq(Llamero::GenerationMode::Auto)
    end

    it "honors LLAMERO_GENERATION_MODE" do
      TestHelpers.with_env({"LLAMERO_GENERATION_MODE" => "schema_prompt"}) do
        Llamero::ConfigLoader.reset!
        Llamero.config.structured_generation_mode.should eq(Llamero::GenerationMode::SchemaPrompt)
      end
    end
  end
end
