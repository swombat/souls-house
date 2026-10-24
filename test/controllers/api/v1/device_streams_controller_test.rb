require "test_helper"
require "support/api_human_key_helpers"

# A person's own device streams through their key (DeviceStreamsController on the web).
class Api::V1::DeviceStreamsControllerTest < ActionDispatch::IntegrationTest

  include ApiHumanKeyHelpers

  setup do
    @subject = users(:user_1)
    @account = accounts(:team_account)
    @headers = human_headers(@subject, @account)
    @stream = DeviceStream.create!(account: @account, subject_user: @subject, name: "Synthetic")
  end

  test "the subject creates a disabled stream, then chooses readers and turns ingestion on" do
    post api_v1_device_streams_path, params: { name: "Chest strap" }, headers: @headers, as: :json
    assert_response :created
    assert_equal "no-store", response.headers["Cache-Control"]
    stream = DeviceStream.find_by!(stream_key: response.parsed_body.dig("device_stream", "id"))
    assert_equal [ @subject, @account, false ], [ stream.subject_user, stream.account, stream.enabled? ]
    assert_empty stream.reader_agent_ids

    reader = agents(:other_account_agent)
    patch api_v1_device_stream_path(stream.stream_key), params: { enabled: true, reader_agent_ids: [ reader.to_param ] },
      headers: @headers, as: :json
    assert_response :success
    assert_equal [ reader.id ], stream.reload.reader_agent_ids
    assert stream.enabled?

    patch api_v1_device_stream_path(stream.stream_key), params: { enabled: false }, headers: @headers, as: :json
    assert_equal [ reader.id ], stream.reload.reader_agent_ids, "an omitted reader list is kept"
    assert_not stream.enabled?
  end

  test "lists and reads only the subject's own streams in this account" do
    other_subject = DeviceStream.create!(account: @account, subject_user: users(:confirmed_user), name: "Not mine")
    elsewhere = DeviceStream.create!(account: accounts(:personal_account), subject_user: @subject, name: "Elsewhere")

    get api_v1_device_streams_path, headers: @headers
    assert_response :success
    assert_equal [ @stream.stream_key ], response.parsed_body["device_streams"].map { |s| s["id"] }

    get api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :success
    assert response.parsed_body.dig("device_stream", "manageable")

    [ other_subject, elsewhere ].each do |stream|
      get api_v1_device_stream_path(stream.stream_key), headers: @headers
      assert_response :not_found
      delete api_v1_device_stream_path(stream.stream_key), headers: @headers
      assert_response :not_found
      assert_nil stream.reload.erased_at
    end
  end

  test "a credential is shown once; reads list it without the token; revoke, erase a session, delete" do
    @stream.update!(enabled: true)
    post credential_api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :created
    token = response.parsed_body.dig("credential", "token")
    assert_match(/\Ashd_[0-9a-f]{64}\z/, token)
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal DeviceStreamCredential.authenticate(token), @stream.device_stream_credentials.last

    get api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_no_match(/shd_[0-9a-f]{64}/, response.body)
    credential_id = response.parsed_body.dig("device_stream", "credentials", 0, "id")

    delete revoke_credential_api_v1_device_stream_path(@stream.stream_key, credential_id), headers: @headers
    assert_response :no_content
    assert @stream.device_stream_credentials.last.revoked_at

    session_id = SecureRandom.uuid
    delete erase_session_api_v1_device_stream_path(@stream.stream_key, session_id), headers: @headers
    assert_response :no_content
    assert @stream.device_stream_sessions.find_by!(session_uuid: session_id).erased_at

    delete erase_session_api_v1_device_stream_path(@stream.stream_key, "not-a-uuid"), headers: @headers
    assert_response :unprocessable_entity

    delete api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :no_content
    assert @stream.reload.erased_at

    post credential_api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :gone
  end

  test "invalid input is refused" do
    post api_v1_device_streams_path, params: { name: "" }, headers: @headers, as: :json
    assert_response :unprocessable_entity

    patch api_v1_device_stream_path(@stream.stream_key), params: { reader_user_ids: [ users(:site_admin_user).to_param ] },
      headers: @headers, as: :json
    assert_response :unprocessable_entity
    assert_empty @stream.reload.reader_user_ids

    @stream.update!(enabled: false)
    post credential_api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :forbidden, "a disabled stream gets no credential"
  end

  test "resident keys are refused" do
    headers = resident_headers(@subject, agents(:research_assistant))
    get api_v1_device_streams_path, headers: headers
    assert_response :forbidden
    post api_v1_device_streams_path, params: { name: "Nope" }, headers: headers, as: :json
    assert_response :forbidden
  end

  test "after leaving the account, the subject can still recover but not manage" do
    @stream.update!(enabled: true)
    credential = @stream.device_stream_credentials.create!(token_digest: SecureRandom.hex(32))
    end_membership!(@subject, @account)

    post api_v1_device_streams_path, params: { name: "New" }, headers: @headers, as: :json
    assert_response :not_found
    patch api_v1_device_stream_path(@stream.stream_key), params: { enabled: false }, headers: @headers, as: :json
    assert_response :not_found
    post credential_api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :not_found

    get api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :success
    assert_not response.parsed_body.dig("device_stream", "manageable")
    assert_nil response.parsed_body.dig("device_stream", "reader_options")

    delete revoke_credential_api_v1_device_stream_path(@stream.stream_key, credential.to_param), headers: @headers
    assert_response :no_content
    delete api_v1_device_stream_path(@stream.stream_key), headers: @headers
    assert_response :no_content
    assert @stream.reload.erased_at
  end

end
