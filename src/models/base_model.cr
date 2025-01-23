require "log"
require "../tokenization/tokenizer"
require "../grammars/base_grammar"
require "../meta_data/meta_data_reader"

# The primary client for interacting directly with models that are available on the local computer.
#
# This class allows the app to switch out specific fune-tuning aspects that improve the models accuracy for specific tasks. This includes:
#   - adding custom `grammars` for customizing response formats
#   - adding or switching out LoRA's
#   - managing the model's context window (token length)
#
# Logs are always disabled with --log-disable when running from within this app
#
# The `chat_template_*` properties are used to wrap the system and user prompts. This is used to generate the prompts for the LLM.
# Chat models are the most commonly used types of models and they are the most likely to be used with this class.
# You can get the symbols you need from the HF repo you got your model from, under the `prompt-template` section.
class Llamero::BaseModel
  # All tokenization behavior lies within this module
  include Llamero::Tokenizer

  # This should be the full _filename_ of the model, including the .gguf file extension.
  #
  # Example: meta-llama-3-8b-instruct-Q6_K.gguf
  property model_name : String = ""

  # The directory where any grammar files will be located
  #
  # Defaults to `/Users/#{`whoami`.strip}/grammars`
  property grammar_root_path : Path = Path["/Users/#{`whoami`.strip}/grammars"]

  # The directory where any lora filters will be located. This is optional, but if you want to use lora filters, you will need to specify this. Lora filters are specific per model they were fine-tune from.
  #
  # Default: /Users/#{`whoami`.strip}/loras
  property lora_root_path : Path = Path["/Users/#{`whoami`.strip}/loras"]

  # The directory where the model files will be located. This is required.
  #
  # Default: /Users/#{`whoami`.strip}/models
  property model_root_path : Path = Path["/Users/#{`whoami`.strip}/models"]

  # Adjust up to punish repetitions more harshly, lower for more monotonous responses. Default: 1.1
  property repeat_penalty : Float32 = 1.1 # --repeat-penalty

  # Adjust up to get more unique responses, adjust down to get more "probable" responses. Default: 80
  property top_k_sampling : Int32 = 80 # --top-k

  # Number of threads. Should be set to the number of physical cores, not logical cores. Default is 12, but should be configured per system for optimal performance.
  property threads : Int32 = 18 # --threads

  # This is just the name of the grammer file, relative to the grammar_root_path. If it's blank, it's not included in the execute command
  property grammar_file : Path = Path.new # --grammer-file

  # Most Llama models use a 2048 context window for their training data. Default: 2048.
  property context_size : Int32 = 2048 # --ctx-size

  # Adjust up or down to play with creativity. Default: 0.9
  property temperature : Float32 = 0.9 # --temperature

  # This can be set by using the `Llamero::Tokenizer#tokenize` method from the `Llamero::Tokenizer` module.
  property keep : String = "" # --keep or --keep N where `N` is the number of tokens to refresh into the context window

  # Setting this changes how many tokens are trying to be predicted at a time. Setting this to -1 will generate tokens infinitely, but causes the context window to reset frequently.
  # Setting this to -2 stops generating as soon as the context window fills up
  # Default: 512
  property n_predict : Int32 = 512

  # The `chat_template_*` properties are used to wrap the system and user prompts. This is used to generate the prompts for the LLM.
  property chat_template_system_prompt_opening_wrapper : String = ""
  property chat_template_system_prompt_closing_wrapper : String = ""
  property chat_template_user_prompt_opening_wrapper : String = ""
  property chat_template_user_prompt_closing_wrapper : String = ""
  property chat_template_end_of_generation_token : String = ""

  # This is a unique token at the end of the prompt that is used to split off and parse the response from the LLM.
  property unique_token_at_the_end_of_the_prompt_to_split_on : String = "\n\r\rAssistant:\n"

  # Sometimes we'll need to use a temporary file to pass the grammar to the LLM. This is the path to that file.
  # We'll clear it after we're done with it, but this isn't meant to be used outside of this class.
  # :nodoc:
  property tmp_grammar_file_path : Path = Path[""]

  # Override any of the default values that are set in the child class
  def initialize(model_name : String,
                 grammar_root_path : Path? = nil,
                 lora_root_path : Path? = nil,
                 model_root_path : Path? = nil,
                 repeat_penalty : Float32? = nil,
                 top_k_sampling : Int32? = nil,
                 threads : Int32? = nil,
                 grammer_file : String? = nil,
                 context_size : Int32? = nil,
                 temperature : Float32? = nil,
                 keep : String? = nil,
                 n_predict : Int32? = nil,
                 chat_template_system_prompt_opening_wrapper : String? = nil,
                 chat_template_system_prompt_closing_wrapper : String? = nil,
                 chat_template_user_prompt_opening_wrapper : String? = nil,
                 chat_template_user_prompt_closing_wrapper : String? = nil,
                 unique_token_at_the_end_of_the_prompt_to_split_on : String? = nil,
                 chat_template_end_of_generation_token : String? = nil)
    raise "Model name does not end in .gguf, the model name must include the file extension" unless model_name.ends_with?(".gguf")

    @model_name = model_name if model_name
    @grammar_root_path = grammar_root_path if grammar_root_path
    @lora_root_path = lora_root_path if lora_root_path
    @model_root_path = model_root_path if model_root_path
    @repeat_penalty = repeat_penalty if repeat_penalty
    @top_k_sampling = top_k_sampling if top_k_sampling
    @threads = threads if threads
    @grammer_file = grammer_file if grammer_file
    @context_size = context_size if context_size
    @temperature = temperature if temperature
    @keep = keep if keep
    @n_predict = n_predict if n_predict

    # Read the meta data from the model file
    @meta_data_reader = Llamero::MetaData::MetaDataReader.new(@model_root_path.join(@model_name))

    # Update the chat template wrappers if they are provided in the initializer
    @chat_template_system_prompt_opening_wrapper = chat_template_system_prompt_opening_wrapper if chat_template_system_prompt_opening_wrapper
    @chat_template_system_prompt_closing_wrapper = chat_template_system_prompt_closing_wrapper if chat_template_system_prompt_closing_wrapper
    @chat_template_user_prompt_opening_wrapper = chat_template_user_prompt_opening_wrapper if chat_template_user_prompt_opening_wrapper
    @chat_template_user_prompt_closing_wrapper = chat_template_user_prompt_closing_wrapper if chat_template_user_prompt_closing_wrapper
    @unique_token_at_the_end_of_the_prompt_to_split_on = unique_token_at_the_end_of_the_prompt_to_split_on if unique_token_at_the_end_of_the_prompt_to_split_on

    if chat_template_end_of_generation_token
      @chat_template_end_of_generation_token = chat_template_end_of_generation_token
    else
      @chat_template_end_of_generation_token = @meta_data_reader.eos_token
    end
  end

  # This is the primary method for interacting with the LLM. It takes a prompt chain, sends the prompt to the LLM and uses concurrency to wait for the response or retry after a timeout threshold.
  #
  # Timeout: 2 minutes
  # Retry: 5 times
  def chat(prompt_chain : Llamero::BasePrompt, grammar_class : Llamero::BaseGrammar, grammar_file : String | Path = Path.new, timeout : Time::Span = Time::Span.new(minutes: 2), max_retries : Int32 = 5, temperature : Float32? = nil, max_tokens : Int32? = nil, repeat_penalty : Float32? = nil, top_k_sampling : Int32? = nil, n_predict : Int32? = nil)
    # Update the instance variables with any of the parameters that were passed in
    @temperature = temperature if temperature
    @context_size = max_tokens if max_tokens
    @repeat_penalty = repeat_penalty if repeat_penalty
    @top_k_sampling = top_k_sampling if top_k_sampling
    @n_predict = n_predict if n_predict
    @grammar_file = grammar_file.is_a?(Path) ? grammar_file : Path[grammar_file]

    grammar_file_command = create_grammar_cli_command(grammar_class, grammar_file)

    prompt_chain.to_llm_instruction_prompt_structure(
      system_prompt_opening_tag: @chat_template_system_prompt_opening_wrapper,
      system_prompt_closing_tag: @chat_template_system_prompt_closing_wrapper,
      user_prompt_opening_tag: @chat_template_user_prompt_opening_wrapper,
      user_prompt_closing_tag: @chat_template_user_prompt_closing_wrapper,
      unique_ending_token: @unique_token_at_the_end_of_the_prompt_to_split_on
    )

    response = run_llama_cpp_bin(prompt_chain.composed_prompt_chain_for_instruction_models, grammar_file_command, max_time_processing: timeout, max_retries: max_retries, grammar_response: grammar_class)
    return response if !response.is_a?(String)
    raise "The LLM response is not a valid response for the grammar class"
  end

  # This is the main method for interacting with the LLM. It takes in an array of messages, and returns the response from the LLM.
  #
  # Default Timeout: 30 seconds
  # Default Max Retries: 5
  def quick_chat(prompt_chain : Array(NamedTuple(role: String, content: String)), grammar_class : Llamero::BaseGrammar? = nil, grammar_file : String | Path = Path.new, temperature : Float32? = nil, max_tokens : Int32? = nil, repeat_penalty : Float32? = nil, top_k_sampling : Int32? = nil, n_predict : Int32? = nil, timeout : Time::Span = Time::Span.new(minutes: 5), max_retries : Int32 = 5) : String
    grammar_file = grammar_file.is_a?(Path) ? grammar_file : Path[grammar_file]

    @temperature = temperature if temperature
    @context_size = max_tokens if max_tokens
    @repeat_penalty = repeat_penalty if repeat_penalty
    @top_k_sampling = top_k_sampling if top_k_sampling
    @n_predict = n_predict if n_predict
    @grammar_file = grammar_file if !grammar_file.basename.blank?

    # Convert the messages to a format that the LLM expects
    new_prompt_messages = [] of Llamero::PromptMessage

    if prompt_chain.first[:role] == "system"
      new_prompt_messages << Llamero::PromptMessage.new(role: "system", content: prompt_chain.first[:content])
    end

    # Change this into a prompting format that more clearly uses the User/Assistant format. Need to look it up in the docs though!
    prompt_chain.each do |message|
      new_prompt_messages << Llamero::PromptMessage.new(role: "user", content: message[:content]) if message[:role] != "system"
    end

    new_base_prompt = BasePrompt.new(messages: new_prompt_messages)

    new_base_prompt.to_llm_instruction_prompt_structure(
      system_prompt_opening_tag: @chat_template_system_prompt_opening_wrapper,
      system_prompt_closing_tag: @chat_template_system_prompt_closing_wrapper,
      user_prompt_opening_tag: @chat_template_user_prompt_opening_wrapper,
      user_prompt_closing_tag: @chat_template_user_prompt_closing_wrapper,
      unique_ending_token: @unique_token_at_the_end_of_the_prompt_to_split_on
    )

    run_llama_cpp_bin(new_base_prompt.composed_prompt_chain_for_instruction_models, "", timeout, max_retries, grammar_response: grammar_class)
  end

  def model_name=(model_name : String)
    @model_name = model_name.split(".").first
  end

  # Create the CLI grammar output or the grammar file command
  private def create_grammar_cli_command(grammar_class : Llamero::BaseGrammar | Nil, grammar_file : Path = Path.new) : String
    # If the grammar_class is present, create the IO for the grammar command
    if grammar_class
      # Write the grammar class IO to a temporary file, and pass the path to that file to the LLM
      @tmp_grammar_file_path = Path["tmp", "grammar_file.gbnf"]
      Dir.mkdir("tmp") unless Dir.exists?("tmp")
      File.write(@tmp_grammar_file_path, grammar_class.to_grammar_file.rewind.gets_to_end)
      return "#{@tmp_grammar_file_path}"
    else
      grammar_file_command = ""
      grammar_file = grammar_file.is_a?(Path) ? grammar_file : Path[grammar_file]
      grammar_file_command = grammar_file.basename.blank? ? "" : "#{@grammar_root_path.join(@grammar_file)}"
      return grammar_file_command
    end
  end

  # Peforms the actual interaction with LLM, including re-trying from failed parsing attempts and timeouts
  private def run_llama_cpp_bin(final_prompt_text : String, grammar_file_command : String, max_time_processing : Time::Span, max_retries : Int32, grammar_response : Llamero::BaseGrammar?)
    response_json = Hash(String, Hash(String, String)).new
    content = Hash(String, String).new

    current_bot_process_output = ""

    query_count = 0

    process_id_channel = Channel(Int64).new(capacity: 1)
    process_output_channel = Channel(IO).new(capacity: 1)
    error_channel = Channel(String).new(capacity: 1)
    query_count_incrementer_channel = Channel(Int32).new(capacity: 1)
    current_processes_id = 0

    # The main loop to run the llama cpp bin & parse a successful response
    while query_count < max_retries
      spawn do
        begin
          output_io = IO::Memory.new
          error_io = IO::Memory.new
          stdin_io = IO::Memory.new

          Log.info { "Interacting with the model..." }

          path_to_llamacpp = `which llamacpp`.chomp

          process_args = [
            "-m",
            "#{model_root_path.join(@model_name)}",
            "--n-predict",
            @n_predict.to_s,
            "--threads",
            @threads.to_s,
            "--ctx-size",
            @context_size.to_s,
            "--temp",
            @temperature.to_s,
            "--top-k",
            @top_k_sampling.to_s,
            "--repeat-penalty",
            @repeat_penalty.to_s,
            # "--log-disable",
            "--prompt",
            final_prompt_text,
          ].select { |r| !r.empty? }

          if !grammar_file_command.blank?
            process_args.insert(2, grammar_file_command)
            process_args.insert(2, "--grammar-file")
          end

          current_process = Process.new(path_to_llamacpp, process_args, output: output_io, error: error_io, input: stdin_io)
          process_id_channel.send(current_process.pid)

          Log.info { "The AI is now processing... please wait" }

          processes_completion_status = current_process.wait

          Log.info { "The process completed with a status of: #{processes_completion_status.inspect}" }

          if processes_completion_status.success?
            Log.info { "Recieved a successful response from the model" }
            query_count_incrementer_channel.send(5)
            process_output_channel.send(output_io.rewind)
          else
            Log.info { "Stderror from the AI model: #{error_io.rewind.gets_to_end}" }
            query_count_incrementer_channel.send(1)
            error_channel.send(error_io.rewind.gets_to_end)
          end
        rescue e
          Log.warn { "error was rescued while trying to query the llm, error: #{e.message}" }
          query_count_incrementer_channel.send(1)
          content["content"] = "error was rescued while trying to query the llm"
        end
      end

      # Here, `select` is a multi-threaded keyword that acts like a blocking mechanism in our main thread to allow for reflecting on the previously spawned fiber based on conditions in the `when`
      select
      when error_recieved = error_channel.receive
        Log.error { "An error occured while processing the LLM: #{error_recieved}" }
        query_count += 1
        a_process_is_already_running = false

        # When the process outputs something, capture it and send it to the content hash
      when content_io = process_output_channel.receive
        begin
          query_count += query_count_incrementer_channel.receive
          Log.info { "We have recieved the the output from the AI, and parsed into the response" }

          if grammar_response
            grammar_response = grammar_response.class.from_json(
              content_io.rewind.gets_to_end.split(
                @unique_token_at_the_end_of_the_prompt_to_split_on
              ).last.gsub(@chat_template_end_of_generation_token, "")
            )
          else
            content["content"] = content_io.rewind.gets_to_end.gsub(@chat_template_end_of_generation_token, "")
          end
        rescue e
          query_count += 1
          Log.error { "An error occured while parsing the response from the AI: #{e.message}. Output being parsed: #{content_io.rewind.gets_to_end}" }
        ensure
          a_process_is_already_running = false
        end
        # Temporarily removing as it causes strange race conditions that have yet to be explained
        # when timeout(max_time_processing)
        #   Log.info { "The timeout was reached, checking..." }

        #   current_processes_id = process_id_channel.receive

        #   Process.signal(Signal::TERM, current_processes_id)
        #   Log.info { "Termineted the original inference process" }

        #   query_count += 1 if !content.has_key?("content") || content["content"].empty?
        #   next
      end
    end

    process_id_channel.close
    process_output_channel.close
    query_count_incrementer_channel.close

    # Return our successfully parsed AI grammar
    if grammar_response
      grammar_response
    else
      content["content"]
    end
  end
end

# This is a helper class for when a user does not provide a grammar, it'll default to responding with a single string property
class DefaultStringResponse < Llamero::BaseGrammar
  property ai_assistant_response : String = ""
end
