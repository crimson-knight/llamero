require "json"
# The BaseTrainingFilter class is the base class for all training filters.
# It organizes the following details to make the filter usable:
# - The PromptMessageTemplates, which include the system prompt and the messages
# - The Expected StructuredResponses from the model, which include the paired completed output
# - The name of the filter, and it's location to be used by the inference command at run-time
class Llamero::BaseTrainingFilter
  include JSON::Serializable

  # Meta data that will get saved into the main `model_filters.json` file
  
  # Human readable name for the filter
  property filter_name : String
  
  # The location of the filter on the file system
  property filter_location : Path
  
  # A description of the use case for the filter, this can be used by a routing model to select the correct filter
  property filter_use_description : String
  
  # The date the filter was created
  property filter_creation_date : Time | Nil

  # Meta data that will get saved into the main `model_filters.json` file
  property prompt_message_template_and_response_pairs : Array(Llamero::PromptAndResponsePairs)

  # Accepts a block that yields the `@prompt_message_template_and_response_pairs` to be modified/created at the time of initialization
  def initialize(@filter_name, @filter_location, @filter_use_description, @prompt_message_template_and_response_pairs, &block)
    @filter_creation_date = Time.now.utc
  end

  # Takes the training prompt pairs, and performs the steps to create the training data in memory
  def create_training_data

  end

  # Persists the training data to disk using the provided path. Defaults to using the application root folder
  def save_training_data_to_disk(path = Path[""])
  end
end

