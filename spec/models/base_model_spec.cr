require "../spec_helper"

describe Llamero::BaseModel do
  it "can be instantiated" do
    base_model = Llamero::BaseModel.new(model_name: "not_really_a_model.gguf")
    base_model.should be_a(Llamero::BaseModel)
  end

  it "raises an error if the model name does not include the .gguf file extension" do
    expect_raises(Exception, "Model name does not end in .gguf, the model name must include the file extension") do
      Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S")
    end
  end

  it "properly takes a prompt sequence of NamedTuples" do
    base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf")

    prompt_sequence_to_test = [
      NamedTuple.new(role: "user", content: "Tell me your best joke for a programming nerd, include in your response the phrase \"Success!\""),
    ]

    io_output = base_model.chat(prompt_sequence_to_test)

    io_output.rewind.gets_to_end.should contain("Success!")
  end

  it "tokenizes a prompt string" do
    base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf")

    prompt_string_to_test = "This is a test, tell me a nerdy coding joke"

    tokenized_prompt = base_model.tokenize(prompt_string_to_test)

    tokenized_prompt.should be_a(Array(String))
    tokenized_prompt.should_not be_empty
  end

  it "tokenizes a prompt string and counts the number of tokens" do
    base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf")

    prompt_string_to_test = "This is a test, tell me a nerdy coding joke"
    token_counter = 0

    tokenized_prompt = base_model.tokenize(text_to_tokenize: prompt_string_to_test, token_counter: token_counter)

    token_counter.should eq(13)
    tokenized_prompt.size.should eq(token_counter)
  end
end
