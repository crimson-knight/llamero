require "../src/llamero"

# Creating a custom grammar means we can interact with the model using natural language, but expect back a valid JSON response that gets parsed directly into a class to interact with.
class StructuredResponse < Llamero::BaseGrammar
  property first_name : String
  property last_name : String
  property age : Int32
  property email : String
end

model = Llamero::BaseModel.new(model_name: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf", chat_template_end_of_generation_token: "<|im_end|>")

response = model.quick_chat([{ role: "user", content: "Write a simple JSON response that follows this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }" }])