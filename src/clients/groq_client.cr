require "./base_api_client"

module Llamero
  # Groq API client for ultra-fast LLM inference
  # Uses OpenAI-compatible API format
  #
  # Note: Groq does not support streaming + tool calling simultaneously
  #
  # ```crystal
  # client = Llamero::GroqClient.new
  # response = client.chat([Message.user("Hello!")])
  # puts response.content
  # ```
  class GroqClient < APIClient
    GROQ_API_URL = "https://api.groq.com/openai"
    DEFAULT_MODEL = "llama-3.3-70b-versatile"

    def initialize(
      api_key : String? = nil,
      base_url : String? = nil,
      default_model : String? = nil,
      timeout : Time::Span = 2.minutes
    )
      super(api_key, base_url, default_model, timeout)
    end

    def provider_name : String
      "Groq"
    end

    protected def get_default_api_key : String
      config.groq_api_key || ""
    end

    protected def get_default_base_url : String
      GROQ_API_URL
    end

    protected def get_default_model : String
      DEFAULT_MODEL
    end

    protected def add_auth_headers(headers : HTTP::Headers) : Nil
      headers["Authorization"] = "Bearer #{@api_key}"
    end

    def supports?(feature : Feature) : Bool
      case feature
      when .structured_output? then true
      when .tool_calling?      then true
      when .streaming?         then true  # Note: Can't combine with tool calling
      when .embeddings?        then false
      when .vision?            then true  # Some models support vision
      else false
      end
    end

    def chat(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil
    ) : ChatResponse(Nil)
      request_body = build_chat_request(messages, model, temperature, max_tokens)
      response = make_request("POST", "/v1/chat/completions", request_body.to_json)

      handle_error_response(response) unless response.success?
      parse_chat_response(response.body, Nil)
    end

    def chat_structured(
      messages : Array(Message),
      response_schema : T.class,
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil
    ) : ChatResponse(T) forall T
      # Build the JSON schema from the grammar class
      schema = T.to_json_schema

      request_body = build_chat_request(messages, model, temperature, max_tokens)

      # Groq uses OpenAI-compatible response_format
      request_body["response_format"] = {
        "type" => "json_schema",
        "json_schema" => {
          "name" => schema["title"]?.try(&.as_s) || "response",
          "strict" => true,
          "schema" => schema
        }
      }

      response = make_request("POST", "/v1/chat/completions", request_body.to_json)
      handle_error_response(response) unless response.success?

      parse_chat_response(response.body, T)
    end

    def chat_stream(
      messages : Array(Message),
      model : String? = nil,
      temperature : Float32? = nil,
      max_tokens : Int32? = nil,
      &block : String -> Nil
    ) : Nil
      request_body = build_chat_request(messages, model, temperature, max_tokens)
      request_body["stream"] = true

      uri = URI.parse(@base_url)

      HTTP::Client.new(uri) do |client|
        client.read_timeout = @timeout
        client.connect_timeout = 30.seconds

        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/json"
        add_auth_headers(headers)

        client.post("/v1/chat/completions", headers: headers, body: request_body.to_json) do |response|
          handle_error_response(response) unless response.success?

          response.body_io.each_line do |line|
            next if line.empty?
            next unless line.starts_with?("data: ")

            data = line[6..]
            next if data == "[DONE]"

            begin
              json = JSON.parse(data)
              if delta = json.dig?("choices", 0, "delta", "content")
                content = delta.as_s?
                block.call(content) if content
              end
            rescue
              # Skip malformed chunks
            end
          end
        end
      end
    end

    private def build_chat_request(
      messages : Array(Message),
      model : String?,
      temperature : Float32?,
      max_tokens : Int32?
    ) : Hash(String, JSON::Any::Type)
      request = {} of String => JSON::Any::Type

      request["model"] = model || @default_model

      # Convert messages to OpenAI format (Groq is OpenAI-compatible)
      request["messages"] = messages.map do |msg|
        msg_hash = {
          "role" => role_to_string(msg.role),
          "content" => msg.content
        } of String => String | Nil

        msg_hash["name"] = msg.name if msg.name
        msg_hash["tool_call_id"] = msg.tool_call_id if msg.tool_call_id

        msg_hash
      end

      request["temperature"] = temperature if temperature
      request["max_tokens"] = max_tokens if max_tokens

      request
    end

    private def role_to_string(role : MessageRole) : String
      case role
      when .system?    then "system"
      when .user?      then "user"
      when .assistant? then "assistant"
      when .tool?      then "tool"
      else "user"
      end
    end

    private def parse_chat_response(body : String, response_type : T.class) : ChatResponse(T) forall T
      json = JSON.parse(body)

      content = json.dig("choices", 0, "message", "content").as_s
      model = json["model"].as_s
      finish_reason = json.dig?("choices", 0, "finish_reason").try(&.as_s) || "stop"

      usage = Usage.new(
        input_tokens: json.dig?("usage", "prompt_tokens").try(&.as_i) || 0,
        output_tokens: json.dig?("usage", "completion_tokens").try(&.as_i) || 0
      )

      # Parse structured response if type provided
      parsed = nil
      {% if T != Nil %}
        begin
          parsed = T.from_json(content)
        rescue ex
          raise APIError.new("Failed to parse structured response: #{ex.message}")
        end
      {% end %}

      ChatResponse(T).new(
        content: content,
        model: model,
        usage: usage,
        finish_reason: finish_reason,
        parsed: parsed
      )
    end
  end
end
