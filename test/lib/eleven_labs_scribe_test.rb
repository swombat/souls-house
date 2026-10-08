require "test_helper"

class ElevenLabsScribeTest < ActiveSupport::TestCase

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

end
