require "../spec_helper"

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
    base_prompt = Llamero::BasePrompt.new(
      system_prompt: "Follow the directions as accurately as you can.",
      messages: [
        Llamero::PromptMessage.new(role: "user", content: "Reply with the the phrase \"Success!\""),
      ]
    )

    base_model = Llamero::BaseModel.new(model_name: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf")

    chat_io_output = base_model.chat(base_prompt)

    puts chat_io_output.rewind.gets_to_end
  end

  it "properly takes a prompt sequence of NamedTuples" do
    base_model = Llamero::BaseModel.new(
      model_name: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf", 
      chat_template_system_prompt_opening_wrapper: "<|begin_of_text|><|start_header_id|>system<|end_header_id|>", 
      chat_template_system_prompt_closing_wrapper: "<|eot_id|>", 
      chat_template_user_prompt_opening_wrapper: "<|start_header_id|>user<|end_header_id|>",
      chat_template_user_prompt_closing_wrapper: "<|eot_id|><|start_header_id|>",
      unique_token_at_the_end_of_the_prompt_to_split_on: "assistant<|end_header_id|>"
    )

    prompt_sequence_to_test = [
      NamedTuple.new(role: "system", content: "Follow the directions as accurately as you can."),
      NamedTuple.new(role: "user", content: "Reply with the the phrase \"Success!\""),
    ]

    io_output = base_model.chat(prompt_sequence_to_test)

    io_output.rewind.gets_to_end.should contain("Success!")
  end

  it "tokenizes a prompt string" do
    base_model = Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K.gguf")

    prompt_string_to_test = "This is a test, tell me a nerdy coding joke"

    tokenized_prompt = base_model.tokenize(prompt_string_to_test)

    tokenized_prompt.should be_a(Array(String))
    tokenized_prompt.size.should eq(12)
  end
end
