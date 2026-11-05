require "test_helper"
require "webmock/minitest"

# Voice mode speech (YMaddY, PR 2). ElevenLabs is stubbed at the HTTP boundary,
# as the house's other ElevenLabs tests do; the real stream's timing was
# measured from prod (YMaddY jLDkAj). Since jEDyze this is the ElevenLabs
# engine only, with the account's own key (SpeechEngine).
class Messages::SpeechesControllerTest < ActionDispatch::IntegrationTest

  STREAM_URL = %r{\Ahttps://api\.elevenlabs\.io/v1/text-to-speech/voice-123/stream\?output_format=mp3_44100_128\z}

  setup do
    Setting.instance.update!(allow_chats: true, voice_mode_scope: "account_choice", speech_engine_scope: "account_choice")
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @account.update!(voice_mode_enabled: true, use_system_ai_credentials: false, openai_api_key: "sk-test-voice-mode",
      speech_engine: "elevenlabs", eleven_labs_api_key: "account-eleven-key")
    @agent = @account.agents.create!(name: "Speaker", system_prompt: "Test", runtime: "external")
    @agent.update_column(:voice_id, "voice-123")
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Voice")
    @chat.agents << @agent
    @reply = @chat.messages.create!(role: "assistant", agent: @agent, content: "Hello **there**.", suppress_automatic_dispatch: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  # The house's key is stubbed only so a test would notice it being used.
  def speak(message)
    ElevenLabsTts.stub(:api_key, "house-eleven-key") { get message_speech_path(message) }
  end

  test "a resident reply streams back as audio from ElevenLabs, in the resident's voice, uncached" do
    stub = stub_request(:post, STREAM_URL)
      .with(headers: { "xi-api-key" => "account-eleven-key" }) { |request| JSON.parse(request.body).values_at("text", "model_id") == [ "Hello there.", ElevenLabsTts::MODEL_ID ] }
      .to_return(status: 200, body: "ID3fake-mp3-bytes", headers: { "Content-Type" => "audio/mpeg" })

    speak(@reply)

    assert_response :success
    assert_requested stub
    assert_equal "audio/mpeg", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "ID3fake-mp3-bytes", response.body
  end

  test "nothing is synthesised when voice mode is off, for a human message, or for another account's chat" do
    stub = stub_request(:post, STREAM_URL)

    @account.update!(voice_mode_enabled: false)
    speak(@reply)
    assert_response :forbidden

    @account.update!(voice_mode_enabled: true)
    human = @chat.messages.create!(role: "user", user: @user, content: "Me.", suppress_automatic_dispatch: true)
    speak(human)
    assert_response :unprocessable_entity

    other = User.create!(email_address: "speech-other@example.com").personal_account
    elsewhere = other.chats.create!(model_id: "openrouter/auto").messages.create!(role: "assistant", content: "Not yours.", suppress_automatic_dispatch: true)
    speak(elsewhere)
    assert_response :not_found

    assert_not_requested stub
  end

  test "an ElevenLabs account without its own key gets the reason, and the house key is never used" do
    stub = stub_request(:post, STREAM_URL)
    @account.update!(eleven_labs_api_key: nil)

    speak(@reply)

    assert_response :unprocessable_entity
    assert_equal "no_eleven_labs_key", response.parsed_body["reason"]
    assert_not_requested stub
  end

  test "under Phonon the server never streams: the browser makes the audio" do
    stub = stub_request(:post, STREAM_URL)

    @account.update!(speech_engine: "phonon")
    speak(@reply)
    assert_response :conflict

    @account.update!(speech_engine: "elevenlabs")
    Setting.instance.update!(speech_engine_scope: "disabled")
    speak(@reply)
    assert_response :conflict, "the site has every account on Phonon"

    assert_not_requested stub
  end

  test "a Conversation resident in an ElevenLabs account is read by Phonon, so nothing streams" do
    stub = stub_request(:post, STREAM_URL)
    ResidentEntitlement.create!(agent: @agent, account: @account, source: "stripe", state: "active", tier: "conversation")

    speak(@reply)

    assert_response :conflict
    assert_not_requested stub
  end

  test "an ElevenLabs refusal before any audio is a 502 with no body" do
    stub_request(:post, STREAM_URL).to_return(status: 429, body: "{}")

    speak(@reply)

    assert_response :bad_gateway
    assert_empty response.body
  end

  test "a transport failure before any audio is a 502, not an empty 200" do
    [ Net::ReadTimeout, Errno::ECONNRESET, EOFError ].each do |failure|
      WebMock.reset!
      stub_request(:post, STREAM_URL).to_raise(failure)

      speak(@reply)

      assert_response :bad_gateway, "#{failure} should be a 502"
      assert_empty response.body
    end
  end

end
