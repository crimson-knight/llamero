require "../spec_helper"

describe Llamero::RetryConfig do
  describe "#initialize" do
    it "creates with default values" do
      config = Llamero::RetryConfig.new
      config.max_retries.should eq(3)
      config.initial_delay.should eq(1.second)
      config.max_delay.should eq(30.seconds)
      config.backoff_multiplier.should eq(2.0)
      config.jitter.should eq(0.1)
    end

    it "creates with custom values" do
      config = Llamero::RetryConfig.new(
        max_retries: 5,
        initial_delay: 500.milliseconds,
        max_delay: 30.seconds,
        backoff_multiplier: 3.0,
        jitter: 0.2
      )
      config.max_retries.should eq(5)
      config.initial_delay.should eq(500.milliseconds)
      config.max_delay.should eq(30.seconds)
      config.backoff_multiplier.should eq(3.0)
      config.jitter.should eq(0.2)
    end
  end

  describe ".aggressive" do
    it "returns an aggressive retry configuration" do
      config = Llamero::RetryConfig.aggressive
      config.max_retries.should eq(5)
      config.initial_delay.should eq(500.milliseconds)
    end
  end

  describe ".conservative" do
    it "returns a conservative retry configuration" do
      config = Llamero::RetryConfig.conservative
      config.max_retries.should eq(2)
      config.initial_delay.should eq(2.seconds)
    end
  end

  describe ".no_retry" do
    it "returns a no-retry configuration" do
      config = Llamero::RetryConfig.no_retry
      config.max_retries.should eq(0)
    end
  end

  describe "#delay_for_attempt" do
    it "calculates exponential delay" do
      config = Llamero::RetryConfig.new(initial_delay: 1.second, jitter: 0.0)

      # First attempt (attempt 0)
      delay0 = config.delay_for_attempt(0)
      delay0.should be_close(1.second, 0.1.seconds)

      # Second attempt (attempt 1)
      delay1 = config.delay_for_attempt(1)
      delay1.should be_close(2.seconds, 0.1.seconds)

      # Third attempt (attempt 2)
      delay2 = config.delay_for_attempt(2)
      delay2.should be_close(4.seconds, 0.1.seconds)
    end

    it "caps delay at max_delay" do
      config = Llamero::RetryConfig.new(
        initial_delay: 10.seconds,
        max_delay: 30.seconds,
        jitter: 0.0
      )

      delay = config.delay_for_attempt(5) # Would be 320 seconds without cap
      delay.should be <= 30.seconds
    end

    it "applies jitter to delay" do
      config = Llamero::RetryConfig.new(initial_delay: 1.second, jitter: 0.2)

      # Run multiple times to check jitter is being applied
      delays = (0..10).map { config.delay_for_attempt(0) }
      unique_delays = delays.uniq

      # With 20% jitter, we should see some variation
      unique_delays.size.should be > 1
    end
  end

  describe "#should_retry?" do
    it "returns false when attempt exceeds max_retries" do
      config = Llamero::RetryConfig.new(max_retries: 3)
      error = Llamero::RateLimitError.new("Rate limit", 429, "", "openai")

      config.should_retry?(error, 0).should be_true
      config.should_retry?(error, 2).should be_true
      config.should_retry?(error, 3).should be_false
      config.should_retry?(error, 4).should be_false
    end

    it "returns true for rate limit errors within max_retries" do
      config = Llamero::RetryConfig.new(max_retries: 3)
      error = Llamero::RateLimitError.new("Rate limit", 429, "", "openai")

      config.should_retry?(error, 0).should be_true
    end

    it "returns true for server errors within max_retries" do
      config = Llamero::RetryConfig.new(max_retries: 3)
      error = Llamero::ServerError.new("Server error", 500, "", "openai")

      config.should_retry?(error, 0).should be_true
    end

    it "returns false for non-retryable errors" do
      config = Llamero::RetryConfig.new(max_retries: 3)
      error = Llamero::AuthenticationError.new("Auth error", 401, "", "openai")

      config.should_retry?(error, 0).should be_false
    end
  end

  describe "#delay_for_error" do
    it "uses Retry-After header for rate limit errors" do
      config = Llamero::RetryConfig.new(initial_delay: 1.second, jitter: 0.0)
      error = Llamero::RateLimitError.new("Rate limit", 429, "", "openai", retry_after: 10.seconds)

      delay = config.delay_for_error(error, 0)
      delay.should eq(10.seconds)
    end

    it "caps Retry-After at max_delay" do
      config = Llamero::RetryConfig.new(max_delay: 30.seconds, jitter: 0.0)
      error = Llamero::RateLimitError.new("Rate limit", 429, "", "openai", retry_after: 60.seconds)

      delay = config.delay_for_error(error, 0)
      delay.should eq(30.seconds)
    end

    it "falls back to exponential delay when no Retry-After" do
      config = Llamero::RetryConfig.new(initial_delay: 1.second, jitter: 0.0)
      error = Llamero::RateLimitError.new("Rate limit", 429, "", "openai")

      delay = config.delay_for_error(error, 1)
      delay.should be_close(2.seconds, 0.1.seconds)
    end

    it "uses exponential delay for server errors" do
      config = Llamero::RetryConfig.new(initial_delay: 1.second, jitter: 0.0)
      error = Llamero::ServerError.new("Server error", 500, "", "openai")

      delay = config.delay_for_error(error, 0)
      delay.should be_close(1.second, 0.1.seconds)
    end
  end
end
