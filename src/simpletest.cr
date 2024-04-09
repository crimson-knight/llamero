require "./models/base_model"
require "./prompts/**"

base_model = Llamero::BaseModel.new(model_name: "mistral-7b-instruct-v0.2.Q5_K_S.gguf")

prompt_sequence_to_test = [
  NamedTuple.new(role: "system", content: "You are am expert Ruby and Crystal developer, your responses must be accurate and helpful."),
  NamedTuple.new(role: "user", content: "How can I write an array of NamedTuples in Crystal?"),
]

io_output = base_model.chat(prompt_sequence_to_test)

puts io_output.rewind.gets_to_end