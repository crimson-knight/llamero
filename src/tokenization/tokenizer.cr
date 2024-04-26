# A helpful module for tokenizing text using the Llamero tokenizer.
#
# If using this module outside of the `Llamero::BaseModel`, then you must define a `model_root_path`
# to the root of the model folder you are using.
module Llamero::Tokenizer
  abstract def model_root_path : Path
  abstract def model_name : String

  # Counts all of the tokens in the given text, returning an array of the parsed tokens
  def tokenize(text_to_tokenize : IO | String) : Array(String)
    raise "Model name cannot be blank" if @model_name.blank?

    output_io = IO::Memory.new
    error_io = IO::Memory.new
    array_of_tokenized_prompt = [] of String

    current_process = Process.new("llamatokenize \"#{model_root_path.join(@model_name)}\" \"#{text_to_tokenize}\"", shell: true, input: Process::Redirect::Pipe, output: output_io, error: error_io)
    current_process.wait # Wait until tokenization is complete

    if error_io.each_line.any?
      raise "Error tokenizing text: #{error_io.rewind.gets_to_end}"
    end

    output_io.rewind.each_line do |line|
      # Check if the line represents a token (starts with a number followed by '->')
      if line =~ /^\s*\d+\s*->/
        # Get the entire token from beside the -> symbol, it starts with a single quote and ends with a single quote
        token = line.split("->").last.strip.gsub(/^'|'$/, "")
        array_of_tokenized_prompt << token
      end
    end

    array_of_tokenized_prompt
  end
end
