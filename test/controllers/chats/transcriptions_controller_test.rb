require "test_helper"

class Chats::TranscriptionsControllerTest < ActionDispatch::IntegrationTest

  # Approved carve-out: keep this controller at the ElevenLabs service seam.
  # VCR-recording realistic STT requests would commit large binary audio cassettes;
  # controller value here is upload/storage/error behavior, not provider payload shape.

  setup do
    Setting.instance.update!(allow_chats: true)

    @user = users(:user_1)
    @account = accounts(:personal_account)
    @chat = @account.chats.create!(
      model_id: "openrouter/auto",
      title: "Test Conversation"
    )

    sign_in @user
  end

  test "transcribes audio and returns text" do
    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, "Hello world") do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio }

      assert_response :success
      json = JSON.parse(response.body)
      assert_equal "Hello world", json["text"]
    end
  end

  test "transcribes before a chat exists without creating a chat" do
    ElevenLabsStt.stub(:transcribe, "First voice note") do
      assert_no_difference "Chat.count" do
        post transcription_account_chats_path(@account),
          params: { audio: fixture_file_upload("test_audio.webm", "audio/webm") }
      end
      assert_response :success
      assert_equal "First voice note", response.parsed_body["text"]
      assert ActiveStorage::Blob.find_signed!(response.parsed_body["audio_signed_id"])
    end
  end

  test "new chat transcription requires authentication" do
    delete logout_path
    post transcription_account_chats_path(@account),
      params: { audio: fixture_file_upload("test_audio.webm", "audio/webm") }
    assert_response :redirect
  end

  test "new chat transcription rejects another account" do
    post transcription_account_chats_path(accounts(:existing_user_account)),
      params: { audio: fixture_file_upload("test_audio.webm", "audio/webm") }
    assert_response :not_found
  end

  test "returns audio_signed_id with successful transcription" do
    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, "Hello world") do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio }

      assert_response :success
      json = JSON.parse(response.body)
      assert json["audio_signed_id"].present?, "Response should include audio_signed_id"
    end
  end

  test "audio_signed_id is a valid ActiveStorage signed id" do
    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, "Hello world") do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio }

      json = JSON.parse(response.body)
      signed_id = json["audio_signed_id"]

      # Should be able to find the blob via the signed_id
      blob = ActiveStorage::Blob.find_signed(signed_id)
      assert blob.present?, "Should find blob from signed_id"
      assert_equal "audio/webm", blob.content_type
    end
  end

  test "returns error when no speech detected" do
    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    ElevenLabsStt.stub(:transcribe, nil) do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio }

      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert_equal "No speech detected", json["error"]
    end
  end

  test "returns error when transcription fails" do
    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    mock_transcribe = ->(_audio) { raise ElevenLabsStt::Error, "Rate limit exceeded" }

    ElevenLabsStt.stub(:transcribe, mock_transcribe) do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: audio }

      assert_response :unprocessable_entity
      json = JSON.parse(response.body)
      assert_includes json["error"], "Rate limit"
    end
  end

  test "rejects request without audio parameter" do
    post account_chat_transcription_path(@account, @chat)

    assert_response :bad_request
  end

  test "rejects request for archived chat" do
    @chat.archive!

    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    post account_chat_transcription_path(@account, @chat),
      params: { audio: audio },
      headers: { "Accept" => "application/json" }

    assert_response :unprocessable_entity
    json = JSON.parse(response.body)
    assert_includes json["error"], "archived or deleted"
  end

  test "requires authentication" do
    delete logout_path

    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    post account_chat_transcription_path(@account, @chat),
      params: { audio: audio }

    assert_response :redirect
  end

  test "scopes to current account" do
    other_user = User.create!(email_address: "sttother@example.com")
    other_user.profile.update!(first_name: "Other", last_name: "User")
    other_account = other_user.personal_account
    other_chat = other_account.chats.create!(model_id: "openrouter/auto")

    audio = fixture_file_upload("test_audio.webm", "audio/webm")

    post account_chat_transcription_path(@account, other_chat),
      params: { audio: audio }

    assert_response :not_found
  end

end
