require "log"
require "../meta_data/meta_data_reader"

# The primary base for all embedding models.
class Llamero::BaseEmbeddingModel

  # This should be the full _filename_ of the model, including the .gguf file extension.
  #
  # Example: meta-llama-3-8b-instruct-Q6_K.gguf
  property model_name : String = ""

  # The directory where any lora filters will be located. This is optional, but if you want to use lora filters, you will need to specify this. Lora filters are specific per model they were fine-tune from.
  # Current unimplemented.
  # Default: /Users/#{`whoami`.strip}/loras
  property lora_root_path : Path = Path["/Users/#{`whoami`.strip}/loras"]

  # The directory where the model files will be located. This is required.
  #
  # Default: /Users/#{`whoami`.strip}/models
  property model_root_path : Path = Path["/Users/#{`whoami`.strip}/models"]

  # Whether to enable logging for the model. This is useful for debugging and understanding the model's behavior.
  #
  # Default: false
  property enable_logging : Bool = false

  # The logging output from running the embedding model. This is not the same output as the Llamero code, this is from the embedding binary.
  property logging_output_from_embedding_model : IO = IO::Memory.new

  # The embeddings that are created by the embedding model
  property embeddings_created : Array(Array(Float64)) = [] of Array(Float64)

  # Creates a logger specifically for the embeddings class
  Log = ::Log.for("embeddings")

  # Override any of the default values that are set in the child class
  def initialize(model_name : String, grammar_root_path : Path? = nil, lora_root_path : Path? = nil, model_root_path : Path? = nil, enable_logging : Bool = false)
    raise "Model name does not end in .gguf, the model name must include the file extension" unless model_name.ends_with?(".gguf")

    @model_name = model_name if model_name
    @lora_root_path = lora_root_path if lora_root_path
    @model_root_path = model_root_path if model_root_path

    # if enable_logging
    #   Log.setup(:debug) 
    # else
    #   Log.setup(:error)
    # end

    # Read the meta data from the model file
    @meta_data_reader = Llamero::MetaData::MetaDataReader.new(@model_root_path.join(@model_name))
  end

  # This is the primary method for creating embeddings. By default it returns an Array(Float64)
  #
  # ```crystal
  # new_embedding = create_embedding_with("Hello, world!")
  # new_embedding.class # => Array(Float64)
  # ```
  #
  # Default Timeout: 30 seconds
  # Default Max Retries: 5
  def create_embedding_with(string_to_create_embedding_with : String, timeout : Time::Span = Time::Span.new(minutes: 2), max_retries : Int32 = 5) : Array(Float64)
    create_embeddings_with([string_to_create_embedding_with], timeout, max_retries)
    @embeddings_created.first
  end

  # This is a method for creating embeddings based on a prompt chain, and accepts a grammar class in case your embedding model creates a response that is different from Array(Float64)
  #
  # Timeout: 2 minutes
  # Retry: 5 times
  def create_embeddings_with(array_of_strings_to_create_embeddings_with : Array(String), timeout : Time::Span = Time::Span.new(minutes: 2), max_retries : Int32 = 5) : Array(Array(Float64))
    # Returns the @embeddings_created array
    run_llama_embedding_bin(array_of_strings_to_create_embeddings_with, timeout, max_retries)
  end

  def model_name=(model_name : String)
    @model_name = model_name.split(".").first
  end

  # Peforms the actual interaction with LLM, including re-trying from failed parsing attempts and timeouts
  private def run_llama_embedding_bin(embeddings_to_create : Array(String), max_time_processing : Time::Span, max_retries : Int32)
    process_response_channel = Channel(EmbeddingProcessResponse).new
    
    embeddings_to_create.each do |embedding_to_create|
      # The main loop to run the llama cpp bin & parse a successful response
      
      model_query_count = 0
      while model_query_count < max_retries
        spawn do
          begin
            output_io = IO::Memory.new
            error_io = IO::Memory.new
            stdin_io = IO::Memory.new

            # Log the interaction with the model if logging is enabled
            Log.info { "Interacting with the model..." }

            # Get the full system path to the llamaembedding binary
            path_to_llamaembedding = `which llamaembedding`.chomp

            process_args = [
              "-m",
              "#{@model_root_path.join(@model_name)}",
              "--prompt",
              embedding_to_create,
            ].select { |r| !r.empty? }

            current_process = Process.new(path_to_llamaembedding, process_args, output: output_io, error: error_io, input: stdin_io)
            embedding_process_response = EmbeddingProcessResponse.new(output: output_io, error: error_io)

            # Log the interaction with the model if logging is enabled
            Log.info { "The AI is now processing... please wait" }

            processes_completion_status = current_process.wait # Wait for the process to complete and then closes any pipes

            if processes_completion_status.success?
              Log.info { "Recieved a successful response from the model" }
              embedding_process_response.success = true
            else
              Log.info { "Stderror from the AI model: #{error_io.rewind.gets_to_end}" }
              embedding_process_response.success = false
            end

            process_response_channel.send(embedding_process_response)
          rescue e
            Log.warn { "error was rescued while trying to query the llm, error: #{e.message}" }
            process_response_channel.send(EmbeddingProcessResponse.new(output: IO::Memory.new, error: IO::Memory.new("error")))
          end
        end

        recieved_response_from_process_channel = process_response_channel.receive

        if recieved_response_from_process_channel.was_successful?
          model_query_count += 5
          parse_embedding_response_into_array_of_floats(recieved_response_from_process_channel.output)
        else
          Log.error { "An error occured while processing the LLM: #{recieved_response_from_process_channel.error.rewind.gets(100)}" }
          model_query_count += 1
        end
      end
    end

    process_response_channel.close

    @embeddings_created
  end


  # Our embedding response comes with a bunch of logging and non-useful output, here we'll parse it into an array of floats.
  # Example output from the SFR-embedding-mistral-q4_k_m.gguf embeddingmodel:
  # ```bash
  #  embedding 0: -0.000000  0.000000  0.000000 -0.000000  0.000000 -0.000000  0.001682  0.001712 -0.000000 ... # There should be more entries to the embedding here
  # ```
  #
  # This will be parsed into:
  # ```crystal
  # [-0.000000, 0.000000, 0.000000, -0.000000, 0.000000, -0.000000, 0.001682, 0.001712, -0.000000, ...]
  # ```
  private def parse_embedding_response_into_array_of_floats(response : IO)
    # Be kind, rewind
    response.rewind

    response.each_line do |io_line|
      if io_line.starts_with?(/^Embedding \d+: /i)
        begin
          # Remove the "Embedding <number>: " prefix and replace double spaces with a single space to make spacing consistent before we split and convert to floats
          embedding_values = io_line.gsub(/^Embedding \d+: /i, "").gsub("  ", " ").lstrip.rstrip.split(" ")
          @embeddings_created << embedding_values.map { |string_float| string_float.to_f }
        rescue e
          raise "Could not parse the embedding response into an array of floats: #{e.message}"
        end
      else
        # Everything that does not start with "embedding" is considered logging output
        @logging_output_from_embedding_model << io_line
      end
    end
  end

  private struct EmbeddingProcessResponse
    property output : IO
    property error : IO
    property success : Bool = false
    
    def initialize(@output, @error)
    end

    def was_successful?
      @success
    end
  end
end
