# How To Write a Grammar | Rules for Writing a `Llamero::Grammar` Subclass

The `Llamero::BaseGrammar` class is the base class for all grammars.

The following rules apply to all grammars:

1. You must inherit from `Llamero::BaseGrammar` or create your own base model that inherits from `Llamero::BaseGrammar`.
2. You only need to define `properties` or other instance variables with the name of the property and the type of the property.
  - Primitive types can be nillable or have a default value
  - Non-primitive types must inherit from `Llamero::BaseGrammar` to be included when creating the expected response structure from the LLM model.
3. It is recommended that you do not write any methods in your grammar class. Any post-processing of the response should be done be reading from the grammars instance.
4. Grammar instances need to be initialized with `from_json` because they implement `JSON::Serializable` but do not have an overload for `initialize` that skips the `JSON::Serializable` implementation.

## Tips for improving the effectiveness of your grammars

1. Your classes property names influence the output of the model, but they do not count towards the number of tokens used in the prompt.
2. Default values are _not included_ when creating the grammar for the LLM's expected response.
3. Prefer using expressive naming that includes clarifying details, `full_name` or `first_name` instead of `name`.

```crystal
class MyGrammar < Llamero::BaseGrammar
  property full_name : String = "" # Good
  property first_name : String = "" # Better
  property current_age : Int32 = 0 # Acceptable
  property current_mailing_address : MyAddress = MyAddress.from_json(%({})) # Initialized with a blank JSON object
end

class MyAddress < Llamero::BaseGrammar
  property street_name_and_number : String = "" # Very good
  property city : String = ""
  property state : String = ""
  property postal_code : String = ""
end
```
