module Llamero
  # Configuration for retry behavior with exponential backoff
  #
  # ```crystal
  # # Default configuration
  # config = RetryConfig.new
  #
  # # Aggressive retries for high-availability
  # config = RetryConfig.aggressive
  #
  # # Conservative retries to avoid costs
  # config = RetryConfig.conservative
  #
  # # No retries
  # config = RetryConfig.no_retry
  # ```
  struct RetryConfig
    # Maximum number of retry attempts per provider
    property max_retries : Int32

    # Initial delay between retries (exponential backoff base)
    property initial_delay : Time::Span

    # Maximum delay between retries
    property max_delay : Time::Span

    # Multiplier for exponential backoff
    property backoff_multiplier : Float64

    # Whether to retry on rate limits (with backoff)
    property retry_on_rate_limit : Bool

    # Whether to retry on server errors (5xx)
    property retry_on_server_error : Bool

    # Jitter to add to delays (0.0-1.0, percentage of delay)
    # Prevents thundering herd when multiple clients hit rate limits
    property jitter : Float64

    def initialize(
      @max_retries : Int32 = 3,
      @initial_delay : Time::Span = 1.second,
      @max_delay : Time::Span = 30.seconds,
      @backoff_multiplier : Float64 = 2.0,
      @retry_on_rate_limit : Bool = true,
      @retry_on_server_error : Bool = true,
      @jitter : Float64 = 0.1
    )
    end

    # Calculate delay for nth retry attempt using exponential backoff
    #
    # ```crystal
    # config = RetryConfig.new(initial_delay: 1.second, backoff_multiplier: 2.0)
    # config.delay_for_attempt(0)  # => ~1 second
    # config.delay_for_attempt(1)  # => ~2 seconds
    # config.delay_for_attempt(2)  # => ~4 seconds
    # ```
    def delay_for_attempt(attempt : Int32) : Time::Span
      base_delay = @initial_delay.total_seconds * (@backoff_multiplier ** attempt)
      capped_delay = Math.min(base_delay, @max_delay.total_seconds)

      # Add jitter to prevent thundering herd
      jitter_range = capped_delay * @jitter
      jittered = capped_delay + (Random.rand * 2 - 1) * jitter_range

      jittered.seconds
    end

    # Should retry this error?
    def should_retry?(error : APIError, attempt : Int32) : Bool
      return false if attempt >= @max_retries

      case error
      when RateLimitError
        @retry_on_rate_limit
      when ServerError
        @retry_on_server_error
      else
        error.retryable
      end
    end

    # Get delay for error, using Retry-After header if available
    def delay_for_error(error : APIError, attempt : Int32) : Time::Span
      if error.is_a?(RateLimitError) && (retry_after = error.retry_after)
        # Use server-provided delay, but cap it
        Math.min(retry_after.total_seconds, @max_delay.total_seconds).seconds
      else
        delay_for_attempt(attempt)
      end
    end

    # Preset: Aggressive retries for high-availability scenarios
    # More retries, faster initial retry, slower backoff
    def self.aggressive : RetryConfig
      new(
        max_retries: 5,
        initial_delay: 500.milliseconds,
        max_delay: 60.seconds,
        backoff_multiplier: 1.5,
        jitter: 0.2
      )
    end

    # Preset: Conservative retries to minimize costs/requests
    # Fewer retries, slower initial retry, faster backoff
    def self.conservative : RetryConfig
      new(
        max_retries: 2,
        initial_delay: 2.seconds,
        max_delay: 30.seconds,
        backoff_multiplier: 3.0,
        jitter: 0.1
      )
    end

    # Preset: No retries at all
    def self.no_retry : RetryConfig
      new(max_retries: 0)
    end

    # Preset: Default balanced configuration
    def self.default : RetryConfig
      new
    end
  end
end
