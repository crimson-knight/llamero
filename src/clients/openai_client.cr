require "./base_api_client"

module Llamero
  # OpenAI API client for chat completions and structured outputs
  #
  # ```crystal
  # client = Llamero::OpenAIClient.new
  # response = client.chat([Message.user("Hello!")])
  # puts response.content
  # ```
  class OpenAIClient < APIClient
    OPENAI_API_URL = "https://api.openai.com"
    DEFAULT_MODEL = "gpt-4o"

    property organization : String?

    def initialize(
      api_key : String? = nil,
      organization : String? = nil,
      base_url : String? = nil,
      default_model : String? = nil,
      timeout : Time::Span = 2.minutes
    )
      @organization = organization || ENV["OPENAI_ORGANIZATION"]? || config.openai_organization
      super(api_key, base_url, default_model, timeout)
    end

    def provider_name : String
      "OpenAI"
    end

    protected def get_default_api_key : String
      config.openai_api_key || ""
    end

    protected def get_default_base_url : String
      OPENAI_API_URL
    end

    protected def get_default_model : String
      config.default_model.starts_with?("gpt") ? config.default_model : DEFAULT_MODEL
    end

    protected def add_auth_headers(headers : HTTP::Headers) : Nil
      headers["Authorization"] = "Bearer #{@api_key}"
      headers["OpenAI-Organization"] = @organization.not_nil! if @organization
    end

    def supports?(feature : Feature) : Bool
      case feature
      when .structured_output? then true
      when .tool_calling?      then true
      when .streaming?         then true
      when .embeddings?        then true
      when .vision?            then true
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

      # Add structured output response format
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

      # Convert messages to OpenAI format
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
      request["max_completion_tokens"] = max_tokens if max_tokens

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
