require "../src/llamero"

# Creating a custom grammar means we can interact with the model using natural language, but expect back a valid JSON response that gets parsed directly into a class to interact with.
class StructuredResponse < Llamero::BaseGrammar
  property first_name : String = ""
  property last_name : String = ""
  property age : Int32 = 0
  property email : String = ""
end

model = Llamero::BaseModel.new(model_name: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf")

start_time = Time.local
response = model.quick_chat([{role: "user", content: "Give me a random persons full name, their age and email address. Your response must be JSON using this template: { \"name\": \"someones name here\", \"age\": 30, \"email\": \"a valid email address\" }"}])
end_time = Time.local

final_time_without_a_grammar = end_time - start_time

puts "Here is the response from Mixtral without a grammar: " + response
puts "Total time taken: #{final_time_without_a_grammar}"

start_time = Time.local

base_prompt = Llamero::BasePrompt.new
base_prompt.add_message(role: "user", content: "Give me a random persons full name, their age and email address.")

response = model.chat(base_prompt, grammar_class: StructuredResponse.from_json(%({})))
end_time = Time.local
total_time_with_grammar = end_time - start_time

puts "Here is the response from Mixtral with a grammar: " + response.to_json
puts "Start time: #{start_time}"
puts "End time: #{end_time}"
puts "Time taken: #{total_time_with_grammar}"

puts "Which version of the model was faster? " + (final_time_without_a_grammar < total_time_with_grammar ? "Mixtral WITHOUT a grammar" : "Mixtral with a grammar")

puts "Final time without a grammar: #{final_time_without_a_grammar}"
puts "Final time with a grammar: #{total_time_with_grammar}"
