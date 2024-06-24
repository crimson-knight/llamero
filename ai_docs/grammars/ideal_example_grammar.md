The following is an example of a grammar subclass that follows all of the conventions and best practices.

```crystal
require "llamero"

# This structured response is useful for when a customer has performed an action and we need a way to determine the next course of action.
# This is for our billing system to determine if the action taken requires us to add a billable item to their account.
# 
# `the_amount_of_the_expense_as_an_integer` is in cents, divide by 100 to get the floating point value.
class CustomerActionInterpretationStructuredResponse < Llamero::BaseGrammar
  property what_we_think_the_customer_did : String = ""
  property does_this_create_an_expense : Bool = false
  property the_amount_of_the_expense_as_an_integer : Int = 0
end
```