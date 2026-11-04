require "test_helper"

class Chats::VoiceModeSessionsControllerTest < ActionDispatch::IntegrationTest

  # Cassettes recorded against api.openai.com on 2026-11-02 from the house.
  # They match on method and URI only: the request carries the account's
  # glossary, whose built-in terms follow the fixtures' resident names.

  setup do
    Setting.instance.update!(allow_chats: true, voice_mode_scope: "account_choice")
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @account.update!(voice_mode_enabled: true, use_system_ai_credentials: false, openai_api_key: "sk-test-voice-mode")
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Voice")
    sign_in @user
  end

  test "answers with a short-lived transcription secret, never the account key" do
    VCR.use_cassette("voice_mode_session_controller", match_requests_on: %i[method uri]) do
      post account_chat_voice_mode_session_path(@account, @chat), as: :json
    end

    assert_response :success
    json = response.parsed_body
    assert json["client_secret"].start_with?("ek_")
    assert_equal "wss://api.openai.com/v1/realtime?intent=transcription", json["socket_url"]
    assert_equal 24_000, json["sample_rate"]
    assert_not_includes response.body, "sk-test-voice-mode"
  end

  test "refused when the account has voice mode off" do
    @account.update!(voice_mode_enabled: false)

    post account_chat_voice_mode_session_path(@account, @chat), as: :json

    assert_response :forbidden
    assert_equal({ "offered" => false, "available" => false, "reason" => "account_disabled" }, response.parsed_body["voice_mode"])
  end

  test "refused when there is no OpenAI key to use" do
    @account.update!(openai_api_key: nil)

    post account_chat_voice_mode_session_path(@account, @chat), as: :json

    assert_response :forbidden
    assert_equal "no_transcription_key", response.parsed_body.dig("voice_mode", "reason")
  end

  test "a refused key is a bad gateway the page can retry" do
    @account.update!(openai_api_key: "sk-not-a-real-key")

    VCR.use_cassette("voice_mode_session_controller_bad_key", match_requests_on: %i[method uri]) do
      post account_chat_voice_mode_session_path(@account, @chat), as: :json
    end

    assert_response :bad_gateway
    assert_equal "The OpenAI API key was refused.", response.parsed_body["error"]
  end

  test "an archived conversation cannot open a session" do
    @chat.update!(archived_at: Time.current)

    post account_chat_voice_mode_session_path(@account, @chat), as: :json

    assert_response :unprocessable_entity
  end

end
