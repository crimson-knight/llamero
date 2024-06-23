Llamero has a strict convention for grammars and how they are supposed to be used.

- `Llamero::BaseGrammar` but be inherited from directly
- Do not define any properties in the grammar class itself
- Your subclass should end with `StructuredResponse` or `ValueObject` or other preferred descriptive name found in the `.llamero_conventions` file
- Use `.from_json` to initialize your grammar class with a JSON object
- Avoid using nilable properties, prefer using default values and checking for default values
- Add class comments that summarize what the grammar is intended to extract or hold as a response
- Add a `.llamero_conventions` file to the root of your project to set the conventions for your project that can be expanded onto

# Grammar Property Naming Conventions
- Use property names that read more like statements, `current_mailing_address` instead of `address`
- Use property names that read like a question, `what_did_this_user_say_their_name_was` instead of `name_of_user`
- Include boundaries in your property names with phrases like `_greater_than` or `_between_` when appropriate
- The property name should express or convey the state of the property that's being accessed or set
- The property name should be a valid Crystal property name
- Property names should be multiple words and include words like `is_this`, `was_this`, `and`, `in` and `or` to convey an interpretted state
