# Directions:
#   Copy this file into your own existing crystal project
#   Change the `require` from the relative require to just requiring the shard
#   Add `llamero` to you shard.yml and run `shards install`
#   Run the file with either `crystal run` or `crystal run`

# require "llamero"
require "../src/llamero"

model = Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K.gguf")

# The `quick_chat` method is a great way to interact with a model quickly when you are not sure on your prompt structure or required grammar structure
response = model.quick_chat([{role: "user", content: "Write a simple JSON response that follows this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }"}])

# This response should not resemble the above requested JSON template, maybe
puts response

# Larger models like mixtral-8x7b are better at following instructions, this usually means longer inference times but less repeat attempts at a correct response
model = Llamero::BaseModel.new(model_name: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf")
response = model.quick_chat([{role: "user", content: "Write a simple JSON response that follows this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }"}])
puts response
