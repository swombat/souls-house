require "test_helper"
require "webmock/minitest"

class ElevenLabsSttTest < ActiveSupport::TestCase

  setup do
    @audio = StringIO.new("fake audio data")
    @api_url = ElevenLabsStt::API_URL
  end

  test "returns stripped text on successful response" do
    stub_request(:post, @api_url)
      .to_return(status: 200, body: { text: "  Hello world  " }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_equal "Hello world", ElevenLabsStt.transcribe(@audio)
    end
  end

  test "returns nil when response text is empty" do
    stub_request(:post, @api_url)
      .to_return(status: 200, body: { text: "" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_nil ElevenLabsStt.transcribe(@audio)
    end
  end

  test "returns nil when response text is whitespace only" do
    stub_request(:post, @api_url)
      .to_return(status: 200, body: { text: "   " }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_nil ElevenLabsStt.transcribe(@audio)
    end
  end

  test "raises on 401 unauthorized" do
    stub_request(:post, @api_url)
      .to_return(status: 401, body: { error: "Unauthorized" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_equal "Invalid ElevenLabs API key", error.message
    end
  end

  [ Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Errno::ECONNRESET,
    Errno::ETIMEDOUT, Errno::ECONNABORTED, Errno::ENETDOWN, Errno::EACCES ].each do |error_class|
    test "normalizes #{error_class} as ElevenLabsStt::Error" do
      stub_request(:post, @api_url).to_raise(error_class)

      Rails.application.credentials.stub(:dig, "test-api-key") do
        error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
        assert_match(/request failed/, error.message)
        assert_instance_of error_class, error.cause
      end
    end
  end

  test "normalizes an unreadable successful response as ElevenLabsStt::Error" do
    stub_request(:post, @api_url).to_return(status: 200, body: "<html>gateway</html>")

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
    end
  end

  test "does not normalize an unrelated outer timeout" do
    stub_request(:post, @api_url).to_raise(Timeout::Error)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      assert_raises(Timeout::Error) { ElevenLabsStt.transcribe(@audio) }
    end
  end

  [ "null", "[]", "42", "true", '"text"', '{"text":42}', '{"text":[]}', '{"text":{}}' ].each do |body|
    test "normalizes invalid successful response shape #{body}" do
      stub_request(:post, @api_url).to_return(status: 200, body: body)

      Rails.application.credentials.stub(:dig, "test-api-key") do
        assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      end
    end
  end

  test "raises on 429 rate limit" do
    stub_request(:post, @api_url)
      .to_return(status: 429, body: { error: "Too many requests" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "rate limit"
    end
  end

  test "raises on 422 with error message from response" do
    stub_request(:post, @api_url)
      .to_return(status: 422, body: { error: { message: "Invalid model identifier" } }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "Invalid model identifier"
    end
  end

  test "raises on 422 with unparseable body" do
    stub_request(:post, @api_url)
      .to_return(status: 422, body: "not json")

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "Invalid request"
    end
  end

  test "raises on 500 server error" do
    stub_request(:post, @api_url)
      .to_return(status: 500, body: "Internal Server Error")

    Rails.application.credentials.stub(:dig, "test-api-key") do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "service unavailable"
    end
  end

  test "raises when API key is not configured" do
    Rails.application.credentials.stub(:dig, nil) do
      error = assert_raises(ElevenLabsStt::Error) { ElevenLabsStt.transcribe(@audio) }
      assert_includes error.message, "not configured"
    end
  end

  test "sends correct headers" do
    request_stub = stub_request(:post, @api_url)
      .with(headers: { "xi-api-key" => "test-api-key" })
      .to_return(status: 200, body: { text: "Hello" }.to_json)

    Rails.application.credentials.stub(:dig, "test-api-key") do
      ElevenLabsStt.transcribe(@audio)
    end

    assert_requested request_stub
  end

end
