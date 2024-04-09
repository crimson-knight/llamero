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
      NamedTuple.new(role: "system", content: "You are am expert Ruby and Crystal developer, your responses must be accurate and helpful."),
      NamedTuple.new(role: "user", content: "How can I write an array of NamedTuples in Crystal?"),
    ]

    io_output = base_model.chat(prompt_sequence_to_test)

    puts io_output.rewind.gets_to_end
    # base_model.prompt_sequence.should be_a(Array)
  end
end

