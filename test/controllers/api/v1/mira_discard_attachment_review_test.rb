require_relative "attachments_controller_test"
module Api
  module V1
    class AttachmentsControllerTest

      test "review: discard retains blob but denies API download and restore permits it" do
        blob = @attachment.blob
        @message.discard!
        assert ActiveStorage::Blob.exists?(blob.id)
        assert @message.reload.attachments.attached?
        get api_v1_conversation_message_attachment_url(@chat, @message, @attachment), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :not_found
        @message.undiscard!
        get api_v1_conversation_message_attachment_url(@chat, @message, @attachment), headers: { "Authorization" => "Bearer #{@token}" }
        assert_response :redirect
      end

    end
  end
end

module Api
  module V1
    class AttachmentsControllerTest

      test "review: retained attachment cannot be freshly downloaded with old web URL" do
        url = @message.files_json.first.fetch(:url)
        @message.discard!
        get url
        follow_redirect! if response.redirect?
        assert_response :not_found
      end

    end
  end
end
