# Directions:
# Copy this file into your own existing crystal project
# Change the `require` from the relative require to just requiring the shard
# Add `llamero` to you shard.yml and run `shards install`
# Run the file with either `crystal run` or `crystal run`

# require "llamero"
require "../src/llamero"

model = Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K.gguf") # llama token: <|eot_id|>        dolphin token: <|im_end|>

response = model.quick_chat([{role: "user", content: "Write a simple JSON response that follows this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }"}])
puts response

model = Llamero::BaseModel.new(model_name: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf")
response = model.quick_chat([{role: "user", content: "Write a simple JSON response that follows this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }"}])
puts response
