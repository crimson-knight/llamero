require "../spec_helper"

describe Llamero::APIError do
  describe "#initialize" do
    it "creates an error with message only" do
      error = Llamero::APIError.new("Something went wrong")
      error.message.should eq("Something went wrong")
      error.status_code.should be_nil
      error.response_body.should be_nil
      error.provider.should be_nil
    end

    it "creates an error with all fields" do
      error = Llamero::APIError.new(
        "API error",
        status_code: 500,
        response_body: "Internal Server Error",
        provider: "openai"
      )
      error.message.should eq("API error")
      error.status_code.should eq(500)
      error.response_body.should eq("Internal Server Error")
      error.provider.should eq("openai")
    end
  end

  describe "#retryable" do
    it "is not retryable by default" do
      error = Llamero::APIError.new("Error")
      error.retryable.should be_false
    end

    it "is retryable for 5xx status codes" do
      error = Llamero::APIError.new("Error", status_code: 503)
      error.retryable.should be_true
    end

    it "is retryable for 429 status code" do
      error = Llamero::APIError.new("Error", status_code: 429)
      error.retryable.should be_true
    end

    it "is not retryable for 4xx status codes (except 429)" do
      error = Llamero::APIError.new("Error", status_code: 400)
      error.retryable.should be_false

      error2 = Llamero::APIError.new("Error", status_code: 401)
      error2.retryable.should be_false
    end
  end
end

describe Llamero::RateLimitError do
  it "creates a rate limit error" do
    error = Llamero::RateLimitError.new(
      "Rate limit exceeded",
      429,
      "Too many requests",
      "openai"
    )
    error.message.should eq("Rate limit exceeded")
    error.status_code.should eq(429)
    error.provider.should eq("openai")
  end

  it "stores retry_after duration" do
    error = Llamero::RateLimitError.new(
      "Rate limit exceeded",
      429,
      "",
      "openai",
      retry_after: 30.seconds
    )
    error.retry_after.should eq(30.seconds)
  end

  it "is always retryable" do
    error = Llamero::RateLimitError.new("Rate limit", 429, "", "openai")
    error.retryable.should be_true
  end
end

describe Llamero::ServerError do
  it "creates a server error" do
    error = Llamero::ServerError.new("Internal error", 500, "Error", "anthropic")
    error.message.should eq("Internal error")
    error.status_code.should eq(500)
  end

  it "is always retryable" do
    error = Llamero::ServerError.new("Error", 502, "", "groq")
    error.retryable.should be_true
  end
end

describe Llamero::AuthenticationError do
  it "creates an authentication error" do
    error = Llamero::AuthenticationError.new("Invalid key", 401, "Unauthorized", "openai")
    error.message.should eq("Invalid key")
    error.status_code.should eq(401)
  end

  it "is never retryable" do
    error = Llamero::AuthenticationError.new("Error", 403, "", "openai")
    error.retryable.should be_false
  end
end

describe Llamero::QuotaExceededError do
  it "creates a quota exceeded error" do
    error = Llamero::QuotaExceededError.new("Quota exceeded", 402, "", "openai")
    error.message.should eq("Quota exceeded")
    error.status_code.should eq(402)
  end

  it "is never retryable" do
    error = Llamero::QuotaExceededError.new("Error", 402, "", "openai")
    error.retryable.should be_false
  end
end

describe Llamero::ModelNotFoundError do
  it "creates a model not found error" do
    error = Llamero::ModelNotFoundError.new("Model not found", 404, "", "openai")
    error.message.should eq("Model not found")
    error.status_code.should eq(404)
  end

  it "is never retryable" do
    error = Llamero::ModelNotFoundError.new("Error", 404, "", "openai")
    error.retryable.should be_false
  end
end

describe Llamero::InvalidRequestError do
  it "creates an invalid request error" do
    error = Llamero::InvalidRequestError.new("Bad request", 400, "", "openai")
    error.message.should eq("Bad request")
    error.status_code.should eq(400)
  end

  it "is never retryable" do
    error = Llamero::InvalidRequestError.new("Error", 400, "", "openai")
    error.retryable.should be_false
  end
end

describe Llamero::FailedAttempt do
  it "creates a failed attempt record" do
    error = Llamero::APIError.new("Error")
    attempt = Llamero::FailedAttempt.new(:openai, error, retry_count: 3)

    attempt.provider.should eq(:openai)
    attempt.error.should eq(error)
    attempt.retry_count.should eq(3)
  end
end
