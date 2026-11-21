require "test_helper"

# The stone fetches the voice of the last reply it was sent, on its own device
# credential, and gets a short-lived storage link, never a lasting one.
class Api::V1::Companion::PocketAudiosControllerTest < ActionDispatch::IntegrationTest

  setup do
    @agent = agents(:research_assistant)
    @agent.update_column(:voice_id, "std-aria")
    pairing, _code, secret = CompanionPairing.open!(name: "The stone", device_request_id: "stone-#{SecureRandom.hex(4)}",
      volumes: nil, kind: "pocket", capabilities: %w[mic])
    pairing.approve!(account: @agent.account, user: users(:user_1), agents: [ @agent ], accesses: {})
    _state, payload = CompanionPairing.claim(pairing.to_param, secret)
    @device, @credential, = CompanionEnrollmentGrant.enroll!(payload["enrollment_token"], payload["device_request_id"])
    chat = @device.chat
    submission = chat.messages.create!(role: "user", user: users(:user_1), content: "hi", suppress_automatic_dispatch: true)
    @reply = chat.messages.create!(role: "assistant", agent: @agent, content: "hello", suppress_automatic_dispatch: true)
    @device.update!(pocket_reply_message_id: @reply.id, pocket_reply_submission_id: submission.id, pocket_replied_at: Time.current)
  end

  def fetch(message = @reply, credential: @credential)
    get "/api/v1/companion/pocket/replies/#{message.to_param}/audio", headers: { "Authorization" => "Bearer #{credential}" }
  end

  def attach_voice
    @reply.voice_audio.attach(io: StringIO.new("ID3"), filename: "v.mp3", content_type: "audio/mpeg",
      metadata: { "voice_digest" => @reply.current_voice_digest })
  end

  test "no credential is refused" do
    fetch(credential: "shcd_nope")
    assert_response :unauthorized
  end

  test "not ready yet says so; ready redirects to a short-lived storage link" do
    fetch
    assert_response :accepted
    assert_equal "not_ready", response.parsed_body["code"]

    attach_voice
    fetch
    assert_response :redirect
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match %r{/rails/active_storage/disk/}, response.location
  end

  test "only the device's own last reply, and only while recent" do
    attach_voice
    other = @device.chat.messages.create!(role: "assistant", agent: @agent, content: "other", suppress_automatic_dispatch: true)
    fetch(other)
    assert_response :not_found

    travel CompanionDevice::Pocket::AUDIO_WINDOW + 1.minute do
      fetch
      assert_response :not_found
    end
  end

  test "a revoked pairing can't fetch a fresh link" do
    attach_voice
    @device.apply_control!("revoke")
    fetch
    assert_response :unauthorized
  end

end
