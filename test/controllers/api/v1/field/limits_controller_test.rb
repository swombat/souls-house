require "test_helper"
require "support/api_human_key_helpers"

class Api::V1::Field::LimitsControllerTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    Setting.instance.update!(allow_agents: true)
    @user = users(:user_1)
    @account = accounts(:personal_account)
  end

  test "a person reads the recording allowance and upload limits the Field page shows" do
    get api_v1_field_limits_path, headers: human_headers(@user, @account)
    assert_response :success
    body = response.parsed_body
    assert_equal FieldItems.allowance_json(@account).stringify_keys.except("used_ms"),
      body["recording_allowance"].except("used_ms")
    assert_equal FieldRecording::MAX_BYTES, body["max_recording_bytes"]
    assert_equal FieldFile::MAX_FILE_SIZE, body["max_file_bytes"]
    assert_equal FieldFile::MAX_FILE_SIZE_LABEL, body["max_file_label"]
  end

  test "resident keys are refused and former members reach nothing" do
    get api_v1_field_limits_path, headers: resident_headers(@user, agents(:research_assistant))
    assert_response :forbidden

    headers = human_headers(@user, @account)
    end_membership!(@user, @account)
    get api_v1_field_limits_path, headers: headers
    assert_response :not_found
  end

end
