require "../src/llamero"

model = Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K.gguf", chat_template_end_of_generation_token: "<|eot_id|>") # llama token: <|eot_id|>        dolphin token: <|im_end|>

start_time = Time.local
response = model.quick_chat([{role: "user", content: "Write a simple JSON response that follows this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }"}])
end_time = Time.local
puts response
puts "Start time: #{start_time}"
puts "End time: #{end_time}"
puts "Time taken: #{end_time - start_time}"

model = Llamero::BaseModel.new(model_name: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf", chat_template_end_of_generation_token: "<|im_end|>")
dolphin_start_time = Time.local
response = model.quick_chat([{role: "user", content: "Write a simple JSON response that follows this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }"}])
dolphin_end_time = Time.local
puts response
puts "Start time: #{dolphin_start_time}"
puts "End time: #{dolphin_end_time}"
puts "Time taken: #{dolphin_end_time - dolphin_start_time}"

puts "Which model was faster? " + (end_time - start_time < dolphin_end_time - dolphin_start_time ? "Llama" : "Dolphin")
