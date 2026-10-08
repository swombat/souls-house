require "test_helper"
require "support/api_human_key_helpers"

class Api::V1::Field::RecordingUploadsControllerTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @headers = human_headers(@user, @account)
  end

  def declaration(**overrides)
    { blob: { filename: "call.webm", content_type: "audio/webm", byte_size: 1024,
              checksum: "#{'A' * 22}==" }.merge(overrides) }
  end

  test "a person declares a recording and gets a direct-upload URL pinned to them and this account" do
    post api_v1_field_recording_uploads_path, params: declaration, headers: @headers, as: :json
    assert_response :created
    body = response.parsed_body
    assert body["signed_id"].present?
    assert body.dig("direct_upload", "url").present?
    blob = ActiveStorage::Blob.find_signed(body["signed_id"])
    assert FieldRecording::Upload.pinned_to?(blob, account: @account, user: @user)
  end

  test "a declaration that isn't audio or video, or is too large, is refused" do
    post api_v1_field_recording_uploads_path, params: declaration(content_type: "text/plain"), headers: @headers, as: :json
    assert_response :unprocessable_entity
    post api_v1_field_recording_uploads_path, params: declaration(byte_size: FieldRecording::MAX_BYTES + 1), headers: @headers, as: :json
    assert_response :unprocessable_entity
    post api_v1_field_recording_uploads_path, params: {}, headers: @headers, as: :json
    assert_response :unprocessable_entity
  end

  test "resident keys are refused and former members reach nothing" do
    assert_no_difference "ActiveStorage::Blob.count" do
      post api_v1_field_recording_uploads_path, params: declaration,
        headers: resident_headers(@user, agents(:research_assistant)), as: :json
      assert_response :forbidden

      end_membership!(@user, @account)
      post api_v1_field_recording_uploads_path, params: declaration, headers: @headers, as: :json
      assert_response :not_found
    end
  end

end
