require "test_helper"
require "webmock/minitest"

# The request body ElevenLabs gets (eOyXXJ): with no delivery, byte for byte
# what it was before delivery existed; with one, its model and settings.
class ElevenLabsTtsTest < ActiveSupport::TestCase

  URL = "https://api.elevenlabs.io/v1/text-to-speech/voice-123"

  def body_sent(delivery)
    body = nil
    stub_request(:post, URL).to_return { |request| body = request.body; { status: 200, body: "ID3" } }
    ElevenLabsTts.synthesize("Hello.", voice_id: "voice-123", api_key: "k", delivery:)
    body
  end

  test "no delivery sends today's body unchanged" do
    expected = {
      text: "Hello.", model_id: "eleven_v3",
      voice_settings: { stability: 0.5, similarity_boost: 0.75, style: 0.0, use_speaker_boost: true, speed: 1.0 }
    }.to_json
    assert_equal expected, body_sent(nil)
  end

  test "a full delivery sends its model and settings, and never the gain" do
    stored = VoiceDelivery.normalize!("model_id" => "eleven_multilingual_v2", "speed" => 0.75, "stability" => 0.75,
      "similarity_boost" => 0.85, "style" => 0.15, "use_speaker_boost" => true, "gain_db" => 10)
    sent = JSON.parse(body_sent(stored))

    assert_equal "eleven_multilingual_v2", sent["model_id"]
    assert_equal({ "stability" => 0.75, "similarity_boost" => 0.85, "style" => 0.15, "use_speaker_boost" => true, "speed" => 0.75 },
      sent["voice_settings"])
    assert_not sent.key?("gain_db")
    assert_not sent["voice_settings"].key?("gain_db")
  end

end
