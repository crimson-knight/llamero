require "./base_api_client"

module Llamero
  # Anthropic Claude API client for chat completions and structured outputs
  #
  # ```crystal
  # client = Llamero::AnthropicClient.new
  # response = client.chat([Message.user("Hello!")])
  # puts response.content
  # ```
  class AnthropicClient < APIClient
    ANTHROPIC_API_URL = "https://api.anthropic.com"
    DEFAULT_MODEL = "claude-sonnet-4-20250514"
    API_VERSION = "2023-06-01"

    def initialize(
      api_key : String? = nil,
      base_url : String? = nil,
      default_model : String? = nil,
      timeout : Time::Span = 2.minutes
    )
      super(api_key, base_url, default_model, timeout)
    end

    def provider_name : String
      "Anthropic"
    end

    protected def get_default_api_key : String
      config.anthropic_api_key || ""
    end

    protected def get_default_base_url : String
      ANTHROPIC_API_URL
    end

    protected def get_default_model : String
      if config.default_model.starts_with?("claude")
        config.default_model
      else
        DEFAULT_MODEL
      end
    end

    protected def add_auth_headers(headers : HTTP::Headers) : Nil
      headers["x-api-key"] = @api_key
      headers["anthropic-version"] = API_VERSION
    end

    def supports?(feature : Feature) : Bool
      case feature
      when .structured_output? then true  # Beta feature
      when .tool_calling?      then true
      when .streaming?         then true
      when .embeddings?        then false # Not supported by Claude
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
      response = make_request("POST", "/v1/messages", request_body.to_json)

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

      # Add structured output response format (Anthropic beta)
      request_body["output_format"] = {
        "type" => "json_schema",
        "json_schema" => schema
      }

      # Add beta header for structured outputs
      headers = HTTP::Headers.new
      headers["anthropic-beta"] = "structured-outputs-2025-01-09"

      response = make_request_with_headers("POST", "/v1/messages", request_body.to_json, headers)
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

        client.post("/v1/messages", headers: headers, body: request_body.to_json) do |response|
          handle_error_response(response) unless response.success?

          response.body_io.each_line do |line|
            next if line.empty?
            next unless line.starts_with?("data: ")

            data = line[6..]

            begin
              json = JSON.parse(data)
              event_type = json["type"]?.try(&.as_s)

              case event_type
              when "content_block_delta"
                if delta = json.dig?("delta", "text")
                  content = delta.as_s?
                  block.call(content) if content
                end
              when "message_stop"
                break
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
      request["max_tokens"] = max_tokens || 4096

      # Anthropic separates system message from other messages
      system_message = messages.find { |m| m.role.system? }
      if system_message
        request["system"] = system_message.content
      end

      # Convert non-system messages to Anthropic format
      request["messages"] = messages.reject { |m| m.role.system? }.map do |msg|
        {
          "role" => role_to_string(msg.role),
          "content" => msg.content
        }
      end

      request["temperature"] = temperature if temperature

      request
    end

    private def role_to_string(role : MessageRole) : String
      case role
      when .user?      then "user"
      when .assistant? then "assistant"
      when .tool?      then "user"  # Tool results go as user messages in Anthropic
      else "user"
      end
    end

    private def make_request_with_headers(
      method : String,
      path : String,
      body : String?,
      extra_headers : HTTP::Headers
    ) : HTTP::Client::Response
      uri = URI.parse(@base_url)

      HTTP::Client.new(uri) do |client|
        client.read_timeout = @timeout
        client.connect_timeout = 30.seconds

        headers = HTTP::Headers.new
        headers["Content-Type"] = "application/json"
        add_auth_headers(headers)

        # Merge extra headers
        extra_headers.each do |key, values|
          values.each { |value| headers.add(key, value) }
        end

        case method.upcase
        when "POST"
          client.post(path, headers: headers, body: body)
        else
          raise APIError.new("Unsupported HTTP method: #{method}")
        end
      end
    end

    private def parse_chat_response(body : String, response_type : T.class) : ChatResponse(T) forall T
      json = JSON.parse(body)

      # Anthropic returns content as an array of content blocks
      content_blocks = json["content"].as_a
      content = content_blocks.map { |block|
        block["text"]?.try(&.as_s) || ""
      }.join

      model = json["model"].as_s
      stop_reason = json["stop_reason"]?.try(&.as_s) || "end_turn"

      usage = Usage.new(
        input_tokens: json.dig?("usage", "input_tokens").try(&.as_i) || 0,
        output_tokens: json.dig?("usage", "output_tokens").try(&.as_i) || 0
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
        finish_reason: stop_reason,
        parsed: parsed
      )
    end
  end
end
