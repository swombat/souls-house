require "test_helper"

module Api
  module V1
    class AttachmentsControllerTest < ActionDispatch::IntegrationTest

      setup do
        @user = users(:confirmed_user)
        @agent = agents(:research_assistant)
        @api_key = ApiKey.generate_for(@user, name: "Hosted agent attachment access", agent: @agent)
        @token = @api_key.raw_token
        @chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Attachment access")
        @chat.agents << @agent
        @message = @chat.messages.create!(content: "Please inspect this file", role: "user", user: @user)
        @message.attachments.attach(
          io: file_fixture("test_document.pdf").open,
          filename: "test_document.pdf",
          content_type: "application/pdf"
        )
        @attachment = @message.attachments_attachments.first
      end

      test "redirects participating agent to a storage download URL" do
        get api_v1_conversation_message_attachment_url(@chat, @message, @attachment),
          headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :redirect
        assert response.location.present?
      end

      test "does not expose attachments from conversations the agent cannot access" do
        other_chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Private conversation")
        other_message = other_chat.messages.create!(content: "Private file", role: "user", user: @user)
        other_message.attachments.attach(
          io: file_fixture("test_document.pdf").open,
          filename: "private.pdf",
          content_type: "application/pdf"
        )
        other_attachment = other_message.attachments_attachments.first

        get api_v1_conversation_message_attachment_url(other_chat, other_message, other_attachment),
          headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :not_found
      end

      test "does not expose an attachment through the wrong message" do
        other_message = @chat.messages.create!(content: "No attachment here", role: "user", user: @user)

        get api_v1_conversation_message_attachment_url(@chat, other_message, @attachment),
          headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :not_found
      end


      test "redirects a participating agent to a dictated message's voice recording" do
        voice = voice_message(@chat)

        get api_v1_conversation_message_attachment_url(@chat, voice, voice.audio_recording_attachment),
          headers: { "Authorization" => "Bearer #{@token}" }

        assert_response :redirect
        assert_includes @message.reload.attachments_for_api.map { |a| a[:kind] }, "file"
        listed = voice.attachments_for_api.sole
        assert_equal [ "voice_recording", voice.audio_recording_attachment.id.to_s ], [ listed[:kind], listed[:id] ]
      end

      test "does not expose a voice recording through another message or another conversation" do
        voice = voice_message(@chat)
        get api_v1_conversation_message_attachment_url(@chat, @message, voice.audio_recording_attachment),
          headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found

        private_chat = @agent.account.chats.create!(model_id: "openrouter/auto", title: "Not joined")
        private_voice = voice_message(private_chat)
        get api_v1_conversation_message_attachment_url(private_chat, private_voice, private_voice.audio_recording_attachment),
          headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      test "a deleted dictated message's recording is not downloadable until the message is restored" do
        voice = voice_message(@chat)
        recording = voice.audio_recording_attachment
        voice.discard!

        get api_v1_conversation_message_attachment_url(@chat, voice, recording),
          headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found

        voice.undiscard!
        get api_v1_conversation_message_attachment_url(@chat, voice, recording),
          headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :redirect
      end

      test "generated voice audio is neither listed nor downloadable" do
        @message.voice_audio.attach(io: StringIO.new("tts"), filename: "voice.mp3", content_type: "audio/mpeg")
        generated = @message.voice_audio_attachment

        refute_includes @message.attachments_for_api.map { |a| a[:id] }, generated.id.to_s
        get api_v1_conversation_message_attachment_url(@chat, @message, generated),
          headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
      end

      private

      def voice_message(chat)
        message = chat.messages.create!(content: "Okay, so we can merge this.", role: "user", user: @user)
        message.audio_recording.attach(io: StringIO.new("audio"), filename: "recording.webm", content_type: "audio/webm")
        message
      end

    end
  end
end
