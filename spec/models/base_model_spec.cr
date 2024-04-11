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
      NamedTuple.new(role: "system", content: "You are a helpful assistant."),
      NamedTuple.new(role: "user", content: "This is a test in our test suite. Please return only \"OK - Test Succeeded\" to confirm that you are working as expected."),
    ]

    io_output = base_model.chat(prompt_sequence_to_test)

    io_output.rewind.gets_to_end.should eq("OK - Test Succeeded")
  end
end

