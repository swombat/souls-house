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

  test "the room's account glossary goes to transcription" do
    TranscriptionGlossary.new(@account).add!("GrantTree", by: @user)
    received = nil

    ElevenLabsStt.stub(:transcribe, ->(_audio, keyterms:) { received = keyterms; "Hi" }) do
      post account_chat_transcription_path(@account, @chat),
        params: { audio: fixture_file_upload("test_audio.webm", "audio/webm") }
    end

    assert_response :success
    assert_includes received, "GrantTree"
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

    mock_transcribe = ->(_audio, **) { raise ElevenLabsStt::Error, "Rate limit exceeded" }

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

  # --- #453: the recording survives a failed transcription -----------------

  test "a provider error keeps the original recording and says it is saved" do
    raising = ->(_audio, **) { raise ElevenLabsStt::Error, "Transcription service unavailable. Please try again." }

    ElevenLabsStt.stub(:transcribe, raising) do
      assert_difference "ActiveStorage::Blob.count", 1 do
        post account_chat_transcription_path(@account, @chat), params: { audio: audio_upload }
      end
    end

    assert_response :unprocessable_entity
    body = response.parsed_body
    assert body["retryable"]
    assert body["saved"]
    blob = ActiveStorage::Blob.find_signed!(body["audio_signed_id"])
    assert_equal file_fixture("test_audio.webm").binread, blob.download, "the original bytes are kept"
    assert_equal({ "user_id" => @user.id, "account_id" => @account.id, "chat_id" => @chat.id }, blob.metadata["voice_note"])
    assert_in_delta (blob.created_at + 7.days).to_i, Time.iso8601(body["expires_at"]).to_i, 1
  end

  test "a timeout and no speech keep the recording too" do
    timeout = ->(_audio, **) { raise ElevenLabsStt::Error, "Transcription request failed (Net::ReadTimeout). Please try again." }

    [ timeout, nil ].each do |outcome|
      ElevenLabsStt.stub(:transcribe, outcome) do
        post account_chat_transcription_path(@account, @chat), params: { audio: audio_upload }
      end
      assert_response :unprocessable_entity
      assert response.parsed_body["saved"]
      assert ActiveStorage::Blob.find_signed(response.parsed_body["audio_signed_id"])
    end
    assert_equal "No speech detected", response.parsed_body["error"]
  end

  test "a storage failure says nothing was saved" do
    failing = ->(**) { raise Errno::ECONNREFUSED }

    ActiveStorage::Blob.stub(:create_and_upload!, failing) do
      ElevenLabsStt.stub(:transcribe, ->(*) { flunk "must not transcribe what was not stored" }) do
        post account_chat_transcription_path(@account, @chat), params: { audio: audio_upload }
      end
    end

    assert_response :service_unavailable
    body = response.parsed_body
    assert_equal false, body["saved"]
    assert body["retryable"]
    assert_nil body["audio_signed_id"]
  end

  test "an oversized recording is refused before anything is stored" do
    stub_const(Message::Attachable, :MAX_FILE_SIZE, 10) do
      assert_no_difference "ActiveStorage::Blob.count" do
        post account_chat_transcription_path(@account, @chat), params: { audio: audio_upload }
      end
    end

    assert_response :content_too_large
    assert_equal false, response.parsed_body["saved"]
  end

  test "retry transcribes the same stored bytes with the glossary, repeatedly, and sends nothing" do
    TranscriptionGlossary.new(@account).add!("GrantTree", by: @user)
    signed_id = failed_recording(@chat)
    seen = []

    ElevenLabsStt.stub(:transcribe, ->(audio, keyterms:) { seen << [ audio.read, audio.original_filename, audio.content_type, keyterms ]; nil }) do
      2.times do
        assert_no_difference [ "ActiveStorage::Blob.count", "Message.count" ] do
          post account_chat_transcription_path(@account, @chat), params: { audio_signed_id: signed_id }
        end
        assert_response :unprocessable_entity
        assert_equal signed_id, response.parsed_body["audio_signed_id"]
      end
    end

    ElevenLabsStt.stub(:transcribe, "Hello again") do
      assert_no_difference "Message.count" do
        post account_chat_transcription_path(@account, @chat), params: { audio_signed_id: signed_id }
      end
    end

    assert_response :success
    assert_equal({ "text" => "Hello again", "audio_signed_id" => signed_id }, response.parsed_body)
    original = file_fixture("test_audio.webm").binread
    assert_equal 2, seen.size
    seen.each do |bytes, filename, content_type, keyterms|
      assert_equal original, bytes, "retry sends the original bytes"
      assert_equal [ "test_audio.webm", "audio/webm" ], [ filename, content_type ]
      assert_includes keyterms, "GrantTree"
    end
  end

  test "a pre-chat recording is retried and discarded only from the new-conversation form" do
    raising = ->(_audio, **) { raise ElevenLabsStt::Error, "Rate limit" }
    ElevenLabsStt.stub(:transcribe, raising) do
      post transcription_account_chats_path(@account), params: { audio: audio_upload }
    end
    signed_id = response.parsed_body["audio_signed_id"]
    assert_nil ActiveStorage::Blob.find_signed!(signed_id).metadata.dig("voice_note", "chat_id")

    post account_chat_transcription_path(@account, @chat), params: { audio_signed_id: signed_id }
    assert_response :not_found

    ElevenLabsStt.stub(:transcribe, "First words") do
      post transcription_account_chats_path(@account), params: { audio_signed_id: signed_id }
    end
    assert_response :success
    assert_equal "First words", response.parsed_body["text"]

    delete transcription_account_chats_path(@account), params: { audio_signed_id: signed_id }
    assert_response :no_content
    assert_nil ActiveStorage::Blob.find_signed(signed_id)
  end

  test "retry and discard refuse anything that is not this person's unsent recording here" do
    other_chat = @account.chats.create!(model_id: "openrouter/auto", title: "Elsewhere")
    mine = failed_recording(@chat)

    other_user = users(:existing_user)
    someone_elses = voice_note_blob(user: other_user, account: @account, chat: @chat)
    other_account = voice_note_blob(user: @user, account: accounts(:existing_user_account), chat: nil)
    plain = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("x" * 2000), filename: "a.webm", content_type: "audio/webm")
    sent = failed_recording(@chat)
    message = @chat.messages.create!(role: "user", user: @user, content: "sent")
    message.audio_recording.attach(sent)

    ElevenLabsStt.stub(:transcribe, ->(*) { flunk "must not transcribe a refused recording" }) do
      {
        "another chat" => [ account_chat_transcription_path(@account, other_chat), mine ],
        "another user" => [ account_chat_transcription_path(@account, @chat), someone_elses.signed_id ],
        "another account" => [ transcription_account_chats_path(@account), other_account.signed_id ],
        "not a voice note" => [ account_chat_transcription_path(@account, @chat), plain.signed_id ],
        "already sent" => [ account_chat_transcription_path(@account, @chat), sent ],
        "bad signature" => [ account_chat_transcription_path(@account, @chat), "nonsense" ]
      }.each do |label, (path, signed_id)|
        post path, params: { audio_signed_id: signed_id }
        assert_response :not_found, "retry: #{label}"
        assert_equal false, response.parsed_body["retryable"], label

        delete path, params: { audio_signed_id: signed_id }
        assert_response :not_found, "discard: #{label}"
      end
    end

    assert ActiveStorage::Blob.find_signed(mine)
    assert message.reload.audio_recording.attached?
  end

  test "discard removes the recording, and a retry afterwards is a clean no longer available" do
    signed_id = failed_recording(@chat)

    delete account_chat_transcription_path(@account, @chat), params: { audio_signed_id: signed_id }
    assert_response :no_content
    assert_nil ActiveStorage::Blob.find_signed(signed_id)

    post account_chat_transcription_path(@account, @chat), params: { audio_signed_id: signed_id }
    assert_response :not_found
    assert_equal false, response.parsed_body["saved"]
  end

  test "a recording discarded while it was being transcribed is reported gone, not saved" do
    signed_id = failed_recording(@chat)
    discarding = lambda do |_audio, **|
      ActiveStorage::Blob.find_signed!(signed_id).purge
      raise ElevenLabsStt::Error, "Transcription service unavailable. Please try again."
    end

    ElevenLabsStt.stub(:transcribe, discarding) do
      post account_chat_transcription_path(@account, @chat), params: { audio_signed_id: signed_id }
    end

    assert_response :not_found
    assert_equal false, response.parsed_body["saved"]
  end

  test "stored bytes that cannot be read are still reported as saved" do
    signed_id = failed_recording(@chat)

    unreadable = ActiveStorage::Blob.find_signed!(signed_id)
    unreadable.define_singleton_method(:open) { |*, **| raise ActiveStorage::FileNotFoundError }

    ActiveStorage::Blob.stub(:find_signed, unreadable) do
      post account_chat_transcription_path(@account, @chat), params: { audio_signed_id: signed_id }
    end

    assert_response :unprocessable_entity
    assert response.parsed_body["saved"]
    assert_includes response.parsed_body["error"], "still saved"
  end

  test "sending a message after its recording was discarded keeps the text and drops the audio" do
    signed_id = failed_recording(@chat)
    ActiveStorage::Blob.find_signed!(signed_id).purge

    assert_difference "Message.count", 1 do
      post account_chat_messages_path(@account, @chat),
        params: { message: { content: "typed instead" }, audio_signed_id: signed_id },
        headers: { "Accept" => "application/json" }
    end

    assert_not Message.last.audio_recording.attached?
  end

  private

  def audio_upload
    fixture_file_upload("test_audio.webm", "audio/webm")
  end

  def failed_recording(chat)
    path = chat ? account_chat_transcription_path(@account, chat) : transcription_account_chats_path(@account)
    ElevenLabsStt.stub(:transcribe, nil) { post path, params: { audio: audio_upload } }
    assert_response :unprocessable_entity
    response.parsed_body.fetch("audio_signed_id")
  end

  def voice_note_blob(user:, account:, chat:)
    ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("x" * 2000), filename: "r.webm", content_type: "audio/webm",
      metadata: { "voice_note" => VoiceNote.metadata_for(user:, account:, chat:) }
    )
  end

  def stub_const(mod, name, value)
    original = mod.const_get(name)
    mod.send(:remove_const, name)
    mod.const_set(name, value)
    yield
  ensure
    mod.send(:remove_const, name)
    mod.const_set(name, original)
  end

end
