module Llamero
  # Base error class for all API-related errors
  # Extended from the existing APIError to add retryability and provider tracking
  class APIError < Exception
    property status_code : Int32?
    property response_body : String?
    property provider : String?
    getter retryable : Bool = false

    def initialize(message : String, @status_code : Int32? = nil, @response_body : String? = nil, @provider : String? = nil)
      super(message)
      @retryable = determine_retryability
    end

    private def determine_retryability : Bool
      return false unless status_code = @status_code
      case status_code
      when 429      then true  # Rate limit
      when 500..599 then true  # Server errors
      else               false
      end
    end
  end

  # Rate limit error (HTTP 429)
  # Retryable with backoff - may include Retry-After header
  class RateLimitError < APIError
    property retry_after : Time::Span?

    def initialize(
      message : String,
      status_code : Int32 = 429,
      response_body : String? = nil,
      provider : String? = nil,
      @retry_after : Time::Span? = nil
    )
      super(message, status_code, response_body, provider)
      @retryable = true
    end
  end

  # Server error (HTTP 500-599)
  # Retryable - the server may recover
  class ServerError < APIError
    def initialize(
      message : String,
      status_code : Int32,
      response_body : String? = nil,
      provider : String? = nil
    )
      super(message, status_code, response_body, provider)
      @retryable = true
    end
  end

  # Authentication error (HTTP 401, 403)
  # NOT retryable - fix the API key
  class AuthenticationError < APIError
    def initialize(
      message : String,
      status_code : Int32 = 401,
      response_body : String? = nil,
      provider : String? = nil
    )
      super(message, status_code, response_body, provider)
      @retryable = false
    end
  end

  # Quota/billing error (HTTP 402)
  # NOT retryable - billing issue needs resolution
  class QuotaExceededError < APIError
    def initialize(
      message : String,
      status_code : Int32 = 402,
      response_body : String? = nil,
      provider : String? = nil
    )
      super(message, status_code, response_body, provider)
      @retryable = false
    end
  end

  # Model not found error (HTTP 404)
  # NOT retryable - wrong model name
  class ModelNotFoundError < APIError
    def initialize(
      message : String,
      status_code : Int32 = 404,
      response_body : String? = nil,
      provider : String? = nil
    )
      super(message, status_code, response_body, provider)
      @retryable = false
    end
  end

  # Invalid request error (HTTP 400)
  # NOT retryable - fix the request
  class InvalidRequestError < APIError
    def initialize(
      message : String,
      status_code : Int32 = 400,
      response_body : String? = nil,
      provider : String? = nil
    )
      super(message, status_code, response_body, provider)
      @retryable = false
    end
  end

  # Record of a failed attempt during failover
  struct FailedAttempt
    property provider : Symbol
    property error : APIError
    property timestamp : Time
    property retry_count : Int32

    def initialize(@provider : Symbol, @error : APIError, @timestamp : Time = Time.utc, @retry_count : Int32 = 0)
    end
  end
end
