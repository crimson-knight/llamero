require "json"

# This class reads the meta data from a gguf model file according to the GGUF/GGML Original File Spec
class Llamero::MetaData::MetaDataReader
  # These constants found in the GGUF/GGML Original File Spec, 
  
  GGUF_METADATA_VALUE_TYPE_UINT8 = 0        # The value is a 8-bit unsigned integer.
  GGUF_METADATA_VALUE_TYPE_INT8 = 1         # The value is a 8-bit signed integer.
  GGUF_METADATA_VALUE_TYPE_UINT16 = 2       # The value is a 16-bit unsigned little-endian integer.
  GGUF_METADATA_VALUE_TYPE_INT16 = 3        # The value is a 16-bit signed little-endian integer.
  GGUF_METADATA_VALUE_TYPE_UINT32 = 4       # The value is a 32-bit unsigned little-endian integer.
  GGUF_METADATA_VALUE_TYPE_INT32 = 5        # The value is a 32-bit signed little-endian integer.
  GGUF_METADATA_VALUE_TYPE_FLOAT32 = 6      # The value is a 32-bit IEEE754 floating point number.
  GGUF_METADATA_VALUE_TYPE_BOOL = 7         # The value is a boolean. 1-byte value where 0 is false and 1 is true.
  GGUF_METADATA_VALUE_TYPE_STRING = 8       # The value is a UTF-8 non-null-terminated string, with length prepended.
  # Arrays can be nested, and the length of the array is the number of elements in the array, not the number of bytes.
  GGUF_METADATA_VALUE_TYPE_ARRAY = 9        # The value is an array of other values, with the length and type prepended.
  GGUF_METADATA_VALUE_TYPE_UINT64 = 10      # The value is a 64-bit unsigned little-endian integer.
  GGUF_METADATA_VALUE_TYPE_INT64 = 11       # The value is a 64-bit signed little-endian integer.
  GGUF_METADATA_VALUE_TYPE_FLOAT64 = 12     # The value is a 64-bit IEEE754 floating point number.

  property model_file_path : Path
  property chat_template : String = ""
  property bos_token : String = ""
  property eos_token : String = ""
  property unknown_token : String = ""
  property separator_token : String = ""
  property padding_token : String = ""
  property file_header : NamedTuple(magic: UInt32, version: UInt32, tensor_count: UInt64, metadata_kv_count: UInt64)
  property tokens_array : Array(JSON::Any) = [] of JSON::Any

  def initialize(@model_file_path)
    @file_header = {magic: 0.to_u32, version: 0.to_u32, tensor_count: 0.to_u64, metadata_kv_count: 0.to_u64} # Initialize to make the compiler happy
    read_meta_data
  end

  def read_meta_data
    File.open(@model_file_path, "r") do |file|
      # Read the header to get the number of metadata key-value pairs
      @file_header = read_header(file)
      metadata_kv_count = @file_header[:metadata_kv_count]

      # Read each metadata key-value pair
      metadata_kv_count.times do
        kv_pair = read_metadata_kv(file)
        
        # TODO: Parse the chat tempalte, it's probably going to be a Jinja or other Python template
        case kv_pair[:key]
        when "tokenizer.ggml.bos_token_id"
          @bos_token = @tokens_array[kv_pair[:value].as(UInt32)].to_s
        when "tokenizer.ggml.eos_token_id"
          @eos_token = @tokens_array[kv_pair[:value].as(UInt32)].to_s
        when "tokenizer.ggml.unknown_token_id"
          @unknown_token = @tokens_array[kv_pair[:value].as(UInt32)].to_s
        when "tokenizer.ggml.separator_token_id"
          @separator_token = @tokens_array[kv_pair[:value].as(UInt32)].to_s
        when "tokenizer.ggml.padding_token_id"
          @padding_token = @tokens_array[kv_pair[:value].as(UInt32)].to_s
        when .includes?("chat_template")
          @chat_template = kv_pair[:value].to_s
        end
      end
    end
  end

  private def read_header(file)
    magic_slice = "GGUF".to_slice
    magic = file.read_bytes(UInt32)
    version = file.read_bytes(UInt32)
    tensor_count = file.read_bytes(UInt64)
    metadata_kv_count = file.read_bytes(UInt64)
    {magic: magic, version: version, tensor_count: tensor_count, metadata_kv_count: metadata_kv_count}
  end

  private def read_metadata_kv(file)
    key = read_gguf_string(file) # Read the key
    value_type = file.read_bytes(UInt32) # Read the value type
    value = read_value(file, value_type)
    {key: key, value: value}
  end

  private def read_gguf_string(file)
    length = file.read_bytes(UInt64)

    begin
      file.read_string(length)
    rescue e
      puts "An error was encountered: #{e.message}"
      ""
    end
  end

  private def read_value(file, value_type)
    case value_type
    when GGUF_METADATA_VALUE_TYPE_UINT8
      file.read_bytes(UInt8)
    when GGUF_METADATA_VALUE_TYPE_INT8
      file.read_bytes(Int8)
    when GGUF_METADATA_VALUE_TYPE_UINT16
      file.read_bytes(UInt16)
    when GGUF_METADATA_VALUE_TYPE_INT16
      file.read_bytes(Int16)
    when GGUF_METADATA_VALUE_TYPE_UINT32
      file.read_bytes(UInt32)
    when GGUF_METADATA_VALUE_TYPE_INT32
      file.read_bytes(Int32)
    when GGUF_METADATA_VALUE_TYPE_FLOAT32
      file.read_bytes(Float32)
    when GGUF_METADATA_VALUE_TYPE_STRING
      read_gguf_string(file)
    when GGUF_METADATA_VALUE_TYPE_UINT64
      file.read_bytes(UInt64)
    when GGUF_METADATA_VALUE_TYPE_INT64
      file.read_bytes(Int64)
    when GGUF_METADATA_VALUE_TYPE_FLOAT64
      file.read_bytes(Float64)
    when GGUF_METADATA_VALUE_TYPE_ARRAY
      array_item_type = file.read_bytes(UInt32)
      array_length = file.read_bytes(UInt64)
      array_length.times do
        @tokens_array << JSON::Any.new(read_value(file, array_item_type))
      end
    end
  end

end
