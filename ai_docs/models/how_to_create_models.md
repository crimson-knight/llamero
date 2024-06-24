# How To Use Llamero Models

### How To Create A Model

Llamero models are created by using the `Llamero::BaseModel` class.

```crystal
model = Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K.gguf")
```

- Models are neat and easy ways to organize your settings for which model and how you want your model to work.
- You can re-use the same model and change the settings in the `chat` method signature if the defaults don't work for your needs.
- Use the `quick_chat` method if you want to quickly test a model.
- Use the `chat` method with a `grammar_class` and `prompt`
- Models must be initialized with a `model_name` that represents the entire file name of the model.
- By default, models will be found relative to the users home directory, under a folder `models`. You can provide a different folder by setting the `model_root_path` named parameter.

```crystal
# How the default model folder is determined.
Path["/Users/#{`whoami`.strip}/models"]
```


### How to use the `chat` method

Required parameters:
- a `Llamero::BasePrompt` or a subclass of `Llamero::BasePrompt` as the first parameter, or named parameter of `prompt_chain`
- `grammar_class` as a named parameter, this should be a class instance of the expected structured response

Optional parameters:
- `max_retries` default of 5, this is the maximum number of attempts to get a valid response from the model
- `temperature` this is a `Float32?`, the default is `0.9` which is fairly creative. Adjust this up or down to adjust the models creativity
- `max_tokens` this is the max tokens for the model to generate. Default is 2048, which includes the system prompt and the provided prompt
- `repeat_penalty` this is a `Float32?`, the default is `1.1` which prevents responses that are too repetative.
- `top_k_sampling` this is an `Int32`, the default is `80` which means the model will only consider the top 80 tokens when generating the next token.
- `n_predict` this is an `Int32`, the default is `512` which means the model will generate 512 tokens in response to the provided prompt.
- `temperature`: a `Float` between 0 and 1. Defaults to 0.5.
- `max_tokens`: an `Int`. Defaults to 1024.

The `grammar_class` that is provided will be the returned value from the `chat` method.

```crystal

class CapitalOfTheMoonStructuredResponse < Llamero::BaseGrammar
  property answer : String
end

prompt = Llamero::BasePrompt.new(
  system_prompt: "You are a helpful assistant.",
  user_prompt: "What is the capital of the moon?"
)

ai_model = Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K.gguf")

response = ai_model.chat(prompt, grammar_class: CapitalOfTheMoonStructuredResponse.from_json(%({})))
```

### How to use the `quick_chat` method

- `quick_chat` accepts an `Array` of `NamedTuples`, each containing a `role` and `content`.
- `quick_chat` returns a `String`.
- This method was designed for doing rapid and simple testing.

```crystal
require "llamero"

model = Llamero::BaseModel.new(model_name: "meta-llama-3-8b-instruct-Q6_K.gguf")

response = model.quick_chat([{ role: "user", content: "What is the capital of the moon?" }])

puts response
```
