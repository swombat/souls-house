require "test_helper"
require "webmock/minitest"

# What the browser reads aloud with Phonon (jEDyze), and Listen's server side:
# the engine comes from SpeechEngine, Phonon gets the shared formatter's text,
# ElevenLabs keeps its stored-audio path with the account's own key, and a
# refusal carries its reason. No path reaches the other engine.
class Messages::SpeechTextsControllerTest < ActionDispatch::IntegrationTest

  include ActiveJob::TestHelper

  setup do
    Setting.instance.update!(allow_chats: true, voice_mode_scope: "account_choice", speech_engine_scope: "account_choice")
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @account.update!(voice_mode_enabled: true, use_system_ai_credentials: false, openai_api_key: "sk-test",
      speech_engine: "phonon", eleven_labs_api_key: nil)
    @agent = @account.agents.create!(name: "Speaker", system_prompt: "Test", runtime: "external")
    @agent.update_column(:voice_id, "voice-123")
    @chat = @account.chats.create!(model_id: "openrouter/auto", title: "Voice")
    @chat.agents << @agent
    @reply = @chat.messages.create!(role: "assistant", agent: @agent,
      content: "In **2026** we had 12 [rooms](https://example.com). See `code`.", suppress_automatic_dispatch: true)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  def text_for(message, mode = nil)
    get message_speech_text_path(message), params: { for: mode }.compact, as: :json
    response.parsed_body
  end

  test "under Phonon the browser gets the formatted text with numbers written out, and the resident's voice" do
    body = text_for(@reply)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "phonon", body["engine"]
    assert body["available"]
    assert_equal "In two thousand and twenty-six we had twelve rooms. See code.", body["text"]
    assert_equal PhononVoices.default.id, body["voice"]

    hugh = PhononVoices.catalogue.find { |voice| voice.name == "Hugh" }
    @agent.update!(phonon_voice: hugh.id)
    assert_equal hugh.id, text_for(@reply)["voice"]
  end

  test "voice mode gets the capped text, Listen the whole of it" do
    long = @chat.messages.create!(role: "assistant", agent: @agent, content: ("A sentence here. " * 120),
      suppress_automatic_dispatch: true)

    assert text_for(long, "voice_mode")["text"].end_with?(VoiceMode::SPEECH_TRUNCATION_NOTE)
    assert_operator text_for(long)["text"].length, :>, VoiceMode::SPEECH_CAP + 100
  end

  test "voice mode's text needs voice mode; Listen's does not" do
    @account.update!(voice_mode_enabled: false)

    get message_speech_text_path(@reply), params: { for: "voice_mode" }, as: :json
    assert_response :forbidden

    assert_equal "phonon", text_for(@reply)["engine"]
  end

  test "under ElevenLabs no text is handed to Phonon, and a missing key is the reason, not a switch" do
    @account.update!(speech_engine: "elevenlabs")
    body = text_for(@reply)
    assert_equal({ "engine" => "elevenlabs", "available" => false, "reason" => "no_eleven_labs_key" },
      body.slice("engine", "available", "reason"))
    assert_nil body["text"]

    @account.update!(eleven_labs_api_key: "account-eleven-key")
    body = text_for(@reply)
    assert_equal [ "elevenlabs", true ], body.values_at("engine", "available")
    assert_nil body["text"]
  end

  test "a human message or another account's message is not read" do
    human = @chat.messages.create!(role: "user", user: @user, content: "Me.", suppress_automatic_dispatch: true)
    get message_speech_text_path(human), as: :json
    assert_response :unprocessable_entity

    other = User.create!(email_address: "speech-text-other@example.com").personal_account
    elsewhere = other.chats.create!(model_id: "openrouter/auto").messages.create!(role: "assistant", content: "No.",
      suppress_automatic_dispatch: true)
    get message_speech_text_path(elsewhere), as: :json
    assert_response :not_found
  end

  test "Listen under Phonon spends nothing on the server" do
    assert_no_enqueued_jobs(only: GenerateVoiceJob) { post message_voice_path(@reply), as: :json }
    assert_response :conflict
    assert_equal "phonon", response.parsed_body["engine"]
  end

  test "Listen under ElevenLabs needs the account's key, then makes the audio with it" do
    @account.update!(speech_engine: "elevenlabs")
    assert_no_enqueued_jobs(only: GenerateVoiceJob) { post message_voice_path(@reply), as: :json }
    assert_response :unprocessable_entity
    assert_match(/no ElevenLabs key of its own/, response.parsed_body["error"])

    @account.update!(eleven_labs_api_key: "account-eleven-key")
    assert_enqueued_with(job: GenerateVoiceJob) { post message_voice_path(@reply), as: :json }
    assert_response :accepted

    stub = stub_request(:post, "https://api.elevenlabs.io/v1/text-to-speech/voice-123")
      .with(headers: { "xi-api-key" => "account-eleven-key" })
      .to_return(status: 200, body: "ID3listen")
    ElevenLabsTts.stub(:api_key, "house-eleven-key") { perform_enqueued_jobs(only: GenerateVoiceJob) }
    assert_requested stub
    assert @reply.reload.voice_audio.attached?
  end

  test "a Listen job queued under ElevenLabs makes nothing once the account is back on Phonon" do
    @account.update!(speech_engine: "elevenlabs", eleven_labs_api_key: "account-eleven-key")
    post message_voice_path(@reply), as: :json
    @account.update!(speech_engine: "phonon")

    stub = stub_request(:post, %r{api\.elevenlabs\.io})
    perform_enqueued_jobs(only: GenerateVoiceJob)
    assert_not_requested stub
    assert_not @reply.reload.voice_audio.attached?
  end

end
