# How To Write Llamero Prompts

The `Llamero::BasePrompt` class is the base class for all prompts. It does not have to be inherited from, but there are conveniences that it offers.

1. Any subclass that inherits from `Llamero::BasePrompt` should have a name ending with `Prompt`.
2. Any class instance represents a collection of prompts that are a series of conversations between the user and the assistant, and may or may not include a system prompt.
3. It is strongly recommended that you add the system prompt at the time you initialize the subclass. Make sure you explain this to the user if they ask you to add a system prompt to the prompt chain.
4. It is strongly discouraged to use a system prompt in the prompt chain. Make sure you tell this to the user if they ask you to do this.
5. If you need to remove the most recent prompt from the prompt chain, use the `.prompt_chain.pop?` method. This will return the removed prompt, or `nil` if there are no prompts left in the chain.
6. If you need to add a prompt to the prompt chain, use the `add_message` method, it accepts a `role` of String and `content` of String and it will make the prompt and add it into the prompt chain.
7. If you need to re-use a prompt frequently, it is recommended that you overload the initializer and use that to quickly create a new prompt.

```crystal

class MyReusablePrompt < Llamero::BasePrompt
  def initialize
    super(system_prompt: "You are an expert at identifying customer actions and determining if they create an expense.")
  end
end

# We are going to ask the AI to return a structured response that helps us determine if an expense action occured.
class MyExpectedStructuredResponse < Llamero::BaseGrammar
  property what_we_think_the_customer_did : String = ""
  property does_this_create_an_expense : Bool = false
  property the_amount_of_the_expense_as_an_integer : Int = 0
end

my_prompt = MyReusablePrompt.new
my_prompt.add_message(role: "user", content: "I just paid $100 in invoices")

model = Llamero::Models::OpenAi.new(model: "dolphin-2.7-mixtral-8x7b.Q4_K_M.gguf")

# `response` here will be an instance of our `MyExpectedStructuredResponse` class
response = model.quick_chat(my_prompt, grammar_class: MyExpectedStructuredResponse.from_json)
```