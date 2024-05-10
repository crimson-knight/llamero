require "../spec_helper"

class TestGrammar < Llamero::BaseGrammar
  property success_response_text : String = ""
  property success_response_random_number_over_100 : Int32 = 0
end


describe Llamero::BaseModel do
  it "can be instantiated" do
    base_model = Llamero::BaseModel.new(model_name: "not_really_a_model.gguf")
    base_model.should be_a(Llamero::BaseModel)
  end

  it "raises an error if the model name does not include the .gguf file extension" do
    expect_raises(Exception, "Model name does not end in .gguf, the model name must include the file extension") do
      Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K")
    end
  end

  it "properly takes a Llamero::BasePrompt" do
    expected_response = TestGrammar.from_json(%({}))

    base_prompt = Llamero::BasePrompt.new(
      system_prompt: "Follow the directions as accurately as you can.",
      messages: [
        Llamero::PromptMessage.new(role: "user", content: "This is just a test, please reply with the phrase \"Test was a Success!\" in your success message and with a random number"),
      ]
    )

    base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf", n_predict: 20)

    actual_response = base_model.chat(base_prompt, expected_response)

    actual_response.success_response_text.should contain("Success!")
    actual_response.success_response_random_number_over_100.should be > 100
  end

  it "properly takes a prompt sequence of NamedTuples" do
    base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf", n_predict: 20)

    prompt_sequence_to_test = [
      NamedTuple.new(role: "system", content: "Follow the directions as accurately as you can."),
      NamedTuple.new(role: "user", content: "This is just a test, please reply with the phrase \"Test was a Success!\" in your success message and with a random number"),
    ]

    io_output = base_model.chat(prompt_sequence_to_test)

    io_output.rewind.gets_to_end.should contain("Success!")
  end

  it "properly uses a grammar and is able to parse a response" do
    base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf", n_predict: 20)

    base_prompt = Llamero::BasePrompt.new(
      system_prompt: "Follow the directions as accurately as you can.",
      messages: [
        Llamero::PromptMessage.new(role: "user", content: "This is just a test, please reply with the phrase \"Test was a Success!\" in your success message and with a random number"),
      ]
    )

    base_grammar = TestGrammar.from_json(%({}))

    chat_io_output = base_model.chat(base_prompt, base_grammar)

    puts "Here is the response we got from the model: "
    puts chat_io_output.rewind.gets_to_end
    puts "\n\n"

    parsed_response = TestGrammar.from_json(chat_io_output.rewind.gets_to_end)
    puts parsed_response.inspect
    parsed_response.success_response_text.should contain("Success!")
    parsed_response.success_response_random_number_over_100.should be > 100
  end

  it "tokenizes a prompt string" do
    base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf")

    prompt_string_to_test = "This is a test, tell me a nerdy coding joke"

    tokenized_prompt = base_model.tokenize(prompt_string_to_test)

    tokenized_prompt.should be_a(Array(String))
    tokenized_prompt.size.should eq(12)
  end
end
