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

  # Override any of the default values that are set in the child class
  def initialize(model_name : String, grammar_root_path : Path? = nil, lora_root_path : Path? = nil, model_root_path : Path? = nil)
    raise "Model name does not end in .gguf, the model name must include the file extension" unless model_name.ends_with?(".gguf")

    @model_name = model_name if model_name
    @lora_root_path = lora_root_path if lora_root_path
    @model_root_path = model_root_path if model_root_path

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
    puts "embeddings_created: #{@embeddings_created.inspect}"
    @embeddings_created.first
  end

  # This is a method for creating embeddings based on a prompt chain, and accepts a grammar class in case your embedding model creates a response that is different from Array(Float64)
  #
  # Timeout: 2 minutes
  # Retry: 5 times
  def create_embeddings_with(array_of_strings_to_create_embeddings_with : Array(String), timeout : Time::Span = Time::Span.new(minutes: 2), max_retries : Int32 = 5) : Array(Array(Float64))
    run_llama_embedding_bin(array_of_strings_to_create_embeddings_with, timeout, max_retries)
  end

  def model_name=(model_name : String)
    @model_name = model_name.split(".").first
  end

  # Peforms the actual interaction with LLM, including re-trying from failed parsing attempts and timeouts
  private def run_llama_embedding_bin(embeddings_to_create : Array(String), max_time_processing : Time::Span, max_retries : Int32)
    model_query_count = 0
    process_output_channel = Channel(IO).new(capacity: 1)
    error_channel = Channel(String).new(capacity: 1)
    query_count_incrementer_channel = Channel(Int32).new(capacity: 1)


    puts "embeddings_to_create: #{embeddings_to_create.inspect}"
    embeddings_to_create.each do |embedding_to_create|
      # The main loop to run the llama cpp bin & parse a successful response
      while model_query_count < max_retries
        spawn do
          begin
            output_io = IO::Memory.new
            error_io = IO::Memory.new
            stdin_io = IO::Memory.new

            # Log the interaction with the model if logging is enabled
            Log.info { "Interacting with the model..." } if enable_logging

            # Get the full system path to the llamaembedding binary
            path_to_llamaembedding = `which llamaembedding`.chomp

            process_args = [
              "-m",
              "#{@model_root_path.join(@model_name)}",
              "--prompt",
              embedding_to_create,
            ].select { |r| !r.empty? }

            current_process = Process.new(path_to_llamaembedding, process_args, output: output_io, error: error_io, input: stdin_io)

            Log.info { "The AI is now processing... please wait" } if enable_logging

            processes_completion_status = current_process.wait # Wait for the process to complete and then closes any pipes

            Log.info { "The process completed with a status of: #{processes_completion_status.inspect}" } if enable_logging

            if processes_completion_status.success?
              Log.info { "Recieved a successful response from the model" } if enable_logging
              query_count_incrementer_channel.send(5) # Increment the query count by 5 to end the loop
              process_output_channel.send(output_io.rewind) # Send the output to the process output channel to get handled by the main fiber
            else
              Log.info { "Stderror from the AI model: #{error_io.rewind.gets_to_end}" } if enable_logging
              query_count_incrementer_channel.send(1) # Increment the query count by 1 to retry the process
              error_channel.send(error_io.rewind.gets_to_end) # Send the error to the error channel to get handled by the main fiber
            end
          rescue e
            Log.warn { "error was rescued while trying to query the llm, error: #{e.message}" } if enable_logging
            query_count_incrementer_channel.send(1) # Increment the query count by 1 to retry the process
          end
        end

        # Here, `select` is a multi-threaded keyword that acts as a blocking mechanism in our main fiber to allow for reflecting on the previously spawned fiber based on conditions in the `when` clauses
        select
        when error_recieved = error_channel.receive
          Log.error { "An error occured while processing the LLM: #{error_recieved}" } if enable_logging
          model_query_count += 1
          a_process_is_already_running = false

        # When the process outputs something, capture it and send it to the content hash
        when content_io = process_output_channel.receive
          begin
            model_query_count += query_count_incrementer_channel.receive
            Log.info { "We have recieved the the output from the AI, and parsed into the response" } if enable_logging

            puts "embedding_to_create: #{embedding_to_create}"
            parse_embedding_response_into_array_of_floats(content_io)
          rescue e
            model_query_count += 1
            Log.error { "An error occured while parsing the response from the AI: #{e.message}. Output being parsed: #{content_io.rewind.gets_to_end}" } if enable_logging
          ensure
            a_process_is_already_running = false
          end
        end
      end
    end

    process_output_channel.close
    query_count_incrementer_channel.close

    @embeddings_created
  end


  # Our embedding response comes with a bunch of logging and non-useful output, here we'll parse it into an array of floats.
  # Example output from the SFR-embedding-mistral-q4_k_m.gguf embeddingmodel:
  # ```bash
  #  embedding 0: -0.000000  0.000000  0.000000 -0.000000  0.000000 -0.000000  0.001682  0.001712 -0.000000
  # ```
  #
  # This will be parsed into:
  # ```crystal
  # [-0.000000, 0.000000, 0.000000, -0.000000, 0.000000, -0.000000, 0.001682, 0.001712, -0.000000]
  # ```
  private def parse_embedding_response_into_array_of_floats(response : IO)
    # Be kind, rewind
    response.rewind

    response.each_line do |io_line|
      if io_line.starts_with?(/^Embedding \d+: /i)
        puts "We have a line with an embedding, current embeddings count: #{@embeddings_created.size}"
        ##
        # begin
        # Remove the "Embedding <number>: " prefix and replace double spaces with a single space to make spacing consistent before we split and convert to floats
          @embeddings_created << io_line.gsub(/^Embedding \d+: /i, "").gsub("  ", " ").split(" ").map(&.to_f)
          ## This `puts` does not ever run because there's an error in the casting line above, but it _should_ run. Uncommenting the `begin..rescue` block will show the error.
          puts "\n\nWe should have one additional embedding now: #{@embeddings_created.size}\n\n"
        # rescue e
        #   File.write("error_line.txt", io_line)
        #   puts "An error occured while parsing the response from the AI: #{e.message}."
        # end
      else
        # Everything that does not start with "embedding" is considered logging output
        @logging_output_from_embedding_model << io_line
      end
    end
  end

end
