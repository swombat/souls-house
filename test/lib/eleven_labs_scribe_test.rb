require "test_helper"

class ElevenLabsScribeTest < ActiveSupport::TestCase

  include WebMock::API

  teardown { WebMock.reset! }

  SECRET = "whsec_test"

  def header(body, at: Time.current, secret: SECRET)
    t = at.to_i
    "t=#{t},v0=#{OpenSSL::HMAC.hexdigest('SHA256', secret, "#{t}.#{body}")}"
  end

  test "a signature made with the secret over timestamp and body is valid" do
    assert ElevenLabsScribe.valid_signature?(header("{}"), "{}", secret: SECRET)
  end

  test "wrong secret, altered body, old or future timestamps, and junk are refused" do
    assert_not ElevenLabsScribe.valid_signature?(header("{}", secret: "other"), "{}", secret: SECRET)
    assert_not ElevenLabsScribe.valid_signature?(header("{}"), "{ }", secret: SECRET)
    assert_not ElevenLabsScribe.valid_signature?(header("{}", at: 31.minutes.ago), "{}", secret: SECRET)
    assert_not ElevenLabsScribe.valid_signature?(header("{}", at: 6.minutes.from_now), "{}", secret: SECRET)
    assert_not ElevenLabsScribe.valid_signature?("v0=abc", "{}", secret: SECRET)
    assert_not ElevenLabsScribe.valid_signature?(nil, "{}", secret: SECRET)
    assert_not ElevenLabsScribe.valid_signature?(header("{}"), "{}", secret: nil)
  end

  test "malformed signature headers are refused, not raised" do
    %w[junk , = t= v0= t=abc,v0=def ,,t=1].each do |header|
      assert_not ElevenLabsScribe.valid_signature?(header, "{}", secret: SECRET), header.inspect
    end
  end

  test "vendor refusals become our own wording, whatever shape the body has" do
    ElevenLabsScribe.stub(:api_key, "k") do
      [ { "detail" => "forbidden" }, { "detail" => { "message" => "secret transcript text" } }, "not json", [ 1, 2 ] ].each do |body|
        stub_request(:delete, %r{api.elevenlabs.io/v1/speech-to-text/transcripts/})
          .to_return(status: 403, body: body.is_a?(String) ? body : body.to_json)
        error = assert_raises(ElevenLabsScribe::PermanentError) { ElevenLabsScribe.new.delete("tr_1") }
        assert_equal "Scribe refused the request (403)", error.message
      end
    end
  end

  test "server errors and rate limits are transient" do
    ElevenLabsScribe.stub(:api_key, "k") do
      [ 429, 503 ].each do |status|
        stub_request(:get, %r{api.elevenlabs.io/v1/speech-to-text/transcripts/}).to_return(status:, body: "{}")
        assert_raises(ElevenLabsScribe::TransientError) { ElevenLabsScribe.new.fetch("tr_1") }
      end
    end
  end

end
