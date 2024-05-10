require "log"
require "../tokenization/tokenizer"
require "../grammars/base_grammar"

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
  # Example: llama-2-13b-chat.Q6_K.gguf
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

  # Adjust up to get more unique responses, adjust down to get more "probable" responses. Default: 40
  property top_k_sampling : Int32 = 40 # --top-k

  # Number of threads. Should be set to the number of physical cores, not logical cores. Default is 12, but should be configured per system for optimal performance.
  property threads : Int32 = 12 # --threads

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

  # This is a unique token at the end of the prompt that is used to split off and parse the response from the LLM.
  property unique_token_at_the_end_of_the_prompt_to_split_on : String = "\n\r\rAssistant:\n"

  # Sometimes we'll need to use a temporary file to pass the grammar to the LLM. This is the path to that file.
  # We'll clear it after we're done with it, but this isn't meant to be used outside of this class.
  # :nodoc:
  property tmp_grammar_file_path : Path = Path[""]

  # Override any of the default values that are set in the child class
  def initialize(model_name : String, grammar_root_path : Path? = nil, lora_root_path : Path? = nil, model_root_path : Path? = nil, repeat_pentalty : Float32? = nil, top_k_sampling : Int32? = nil, threads : Int32? = nil, grammer_file : String? = nil, context_size : Int32? = nil, temperature : Float32? = nil, keep : String? = nil, n_predict : Int32? = nil, chat_template_system_prompt_opening_wrapper : String? = nil, chat_template_system_prompt_closing_wrapper : String? = nil, chat_template_user_prompt_opening_wrapper : String? = nil, chat_template_user_prompt_closing_wrapper : String? = nil, unique_token_at_the_end_of_the_prompt_to_split_on : String? = nil)
    raise "Model name does not end in .gguf, the model name must include the file extension" unless model_name.ends_with?(".gguf")

    @model_name = model_name if model_name
    @grammar_root_path = grammar_root_path if grammar_root_path
    @lora_root_path = lora_root_path if lora_root_path
    @model_root_path = model_root_path if model_root_path
    @repeat_pentalty = repeat_pentalty if repeat_pentalty
    @top_k_sampling = top_k_sampling if top_k_sampling
    @threads = threads if threads
    @grammer_file = grammer_file if grammer_file
    @context_size = context_size if context_size
    @temperature = temperature if temperature
    @keep = keep if keep
    @n_predict = n_predict if n_predict

    # Update the chat template wrappers if they are provided in the initializer
    @chat_template_system_prompt_opening_wrapper = chat_template_system_prompt_opening_wrapper if chat_template_system_prompt_opening_wrapper
    @chat_template_system_prompt_closing_wrapper = chat_template_system_prompt_closing_wrapper if chat_template_system_prompt_closing_wrapper
    @chat_template_user_prompt_opening_wrapper = chat_template_user_prompt_opening_wrapper if chat_template_user_prompt_opening_wrapper
    @chat_template_user_prompt_closing_wrapper = chat_template_user_prompt_closing_wrapper if chat_template_user_prompt_closing_wrapper
    @unique_token_at_the_end_of_the_prompt_to_split_on = unique_token_at_the_end_of_the_prompt_to_split_on if unique_token_at_the_end_of_the_prompt_to_split_on
  end

  # This is the primary method for interacting with the LLM. It takes a prompt chain, sends the prompt to the LLM and uses concurrency to wait for the response or retry after a timeout threshold.
  #
  # This is the preferred method over passing in an array of `NamedTuple`s.
  #
  # Timeout: 30 seconds
  # Retry: 5 times
  def chat(prompt_chain : Llamero::BasePrompt, grammar_class : Llamero::BaseGrammar, grammar_file : String | Path = Path.new, timeout : Time::Span = Time::Span.new(seconds: 30), max_retries : Int32 = 5, temperature : Float32? = nil, max_tokens : Int32? = nil, repeat_penalty : Float32? = nil, top_k_sampling : Int32? = nil, n_predict : Int32? = nil)
    # Update the instance variables with any of the parameters that were passed in
    @temperature = temperature if temperature
    @context_size = max_tokens if max_tokens
    @repeat_pentalty = repeat_penalty if repeat_penalty
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

    run_llama_cpp_bin(prompt_chain.composed_prompt_chain_for_instruction_models, grammar_file_command, max_time_processing: timeout, max_retries: max_retries, grammar_response: grammar_class)
  end

  # This is the main method for interacting with the LLM. It takes in an array of messages, and returns the response from the LLM.
  #
  # Default Timeout: 30 seconds
  # Default Max Retries: 5
  def quick_chat(prompt_chain : Array(NamedTuple(role: String, content: String)), grammar_class : Llamero::BaseGrammar? = nil, grammar_file : String | Path = Path.new, temperature : Float32? = nil, max_tokens : Int32? = nil, repeat_penalty : Float32? = nil, top_k_sampling : Int32? = nil, n_predict : Int32? = nil, timeout : Time::Span = Time::Span.new(seconds: 30), max_retries : Int32 = 5)
    grammar_file = grammar_file.is_a?(Path) ? grammar_file : Path[grammar_file]

    @temperature = temperature if temperature
    @context_size = max_tokens if max_tokens
    @repeat_pentalty = repeat_penalty if repeat_penalty
    @top_k_sampling = top_k_sampling if top_k_sampling
    @n_predict = n_predict if n_predict
    @grammar_file = grammar_file if !grammar_file.basename.blank?
    grammar_file_command = create_grammar_cli_command(grammar_class, grammar_file)

    if grammar_class
      grammar_file_command = "#{@grammar_root_path.join(@grammar_file)}" + grammar_file_command
    end

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

    if grammar_class
      chat(new_base_prompt, grammar_class, grammar_file, temperature: @temperature, max_tokens: @context_size, repeat_penalty: @repeat_penalty, top_k_sampling: @top_k_sampling, n_predict: n_predict, timeout: timeout, max_retries: max_retries)
    else
      new_base_grammar = DefaultStringResponse.from_json(%({}))
      chat(new_base_prompt, new_base_grammar, grammar_file, temperature: @temperature, max_tokens: @context_size, repeat_penalty: @repeat_penalty, top_k_sampling: @top_k_sampling, n_predict: n_predict, timeout: timeout, max_retries: max_retries)
    end
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
  private def run_llama_cpp_bin(final_prompt_text : String, grammar_file_command : String, max_time_processing : Time::Span, max_retries : Int32, grammar_response : Llamero::BaseGrammar? = nil)
    response_json = Hash(String, Hash(String, String)).new
    content = Hash(String, String).new

    current_bot_process_output = ""

    query_count = 0
    successfully_completed_chat_completion = false

    process_id_channel = Channel(Int64).new(capacity: 1)
    process_output_channel = Channel(IO).new(capacity: 1)
    error_channel = Channel(String).new(capacity: 1)
    query_count_incrementer_channel = Channel(Int32).new(capacity: 1)

    # The main loop to run the llama cpp bin & parse a successful response
    while query_count < max_retries
      spawn do
        begin
          output_io = IO::Memory.new
          error_io = IO::Memory.new
          stdin_io = IO::Memory.new

          Log.info { "Interacting with the model" }

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
            @repeat_pentalty.to_s, 
            "--log-disable", 
            "--prompt", 
            final_prompt_text].select { |r| !r.empty? }

          if !grammar_file_command.blank?
            process_args.insert(2, grammar_file_command)
            process_args.insert(2, "--grammar-file")
          end

          current_process = Process.new(path_to_llamacpp, process_args, output: output_io, error: error_io, input: stdin_io)
          process_id_channel.send(current_process.pid)
          current_process.wait

          if error_io.rewind.gets_to_end.blank?
            Log.info { "Recieved a successful response from the model" }
            query_count_incrementer_channel.send(5)
            process_output_channel.send(output_io.rewind)
          else
            Log.info { "Stderror has output, so there was an error: #{error_io.rewind.gets_to_end}" }
            query_count_incrementer_channel.send(1)
            error_channel.send(error_io.rewind.gets_to_end)
          end
        rescue e
          Log.warn { "error was rescued while trying to query the llm, error: #{e.message}" }
          query_count_incrementer_channel.send(1)
          content["content"] = "error was rescued while trying to query the llm"
        end
      end

      Log.info { "The AI is now processing... please wait" }

      # Multi-threaded keyword here, this acts like a blocking mechanism to allow for reflecting on the previously spawned fiber
      select
      when error_recieved = error_channel.receive
        Log.error { "An error occured while processing the LLM: #{error_recieved}" }
        query_count += 1

        # When the process outputs something, capture it and send it to the content hash
      when content_io = process_output_channel.receive
        query_count += query_count_incrementer_channel.receive
        content["content"] = content_io.gets_to_end.split(@unique_token_at_the_end_of_the_prompt_to_split_on).last
        Log.info { "We have recieved the the output from the AI, and parsed into the response" }

        begin
          grammar_response.class.from_json(content["content"])
        rescue
          grammar_response = DefaultStringResponse.from_json(content["content"])
        end

        if grammar_response
          grammar_response.class.from_json(content["content"])
        end
      when timeout(max_time_processing)
        Log.info { "The AI took too long, restarting the query now" }

        if Process.exists?(process_id_channel.receive)
          Log.info { "The process is still running, let's wait for the output channel to receive something" }

          sleep max_time_processing

          Log.info { "checking the process output again..." }
          output = process_output_channel.receive
          content["content"] = output.gets_to_end

          Log.info { "We have a completed response from the AI." }
          Log.info { content["content"] }
        end

        # If the pid for the process is still running, check the last output for this process and compare it to the last known output. If it's the same, kill the process and move on
        if !content.has_key?("content") || content["content"].empty?
          content["content"] = %({ "error": "5 attempts were made to generate a chat completion and timed out or errored every time. Try changing your prompt." })
        end

        query_count += 1 if content["content"].empty?
      end
    end

    process_id_channel.close
    process_output_channel.close
    query_count_incrementer_channel.close

    # If the grammar response is a Llamero::BaseGrammar, parse the response into the grammar_response object
    if grammar_response.is_a?(Llamero::BaseGrammar)
      grammar_response.class.from_json(content["content"])
    else
      DefaultStringResponse.from_json(content["content"])
    end
  end
end

# This is a helper class for when a user does not provide a grammar, it'll default to responding with a single string property
class DefaultStringResponse < Llamero::BaseGrammar
  property ai_assistant_response : String
end
