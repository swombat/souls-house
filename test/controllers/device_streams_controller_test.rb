require "test_helper"

class DeviceStreamsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @subject = users(:user_1)
    @account = accounts(:team_account)
    @stream = DeviceStream.create!(account: @account, subject_user: @subject, name: "Synthetic")
    sign_in(@subject)
  end

  test "subject creates disabled stream and chooses readers" do
    post account_device_streams_path(@account), params: { name: "New" }
    stream = DeviceStream.order(:id).last
    assert_redirected_to device_stream_path(stream.stream_key)
    assert_equal @subject, stream.subject_user
    assert_not stream.enabled?
    assert_empty stream.reader_agent_ids
    patch device_stream_path(stream.stream_key), params: { enabled: "1", reader_agent_ids: [ agents(:other_account_agent).to_param ] }
    assert_redirected_to device_stream_path(stream.stream_key)
    assert_equal [ agents(:other_account_agent).id ], stream.reload.reader_agent_ids
  end

  test "browser controls expose revoke erase and one-time credential" do
    get device_stream_path(@stream.stream_key)
    assert_response :success
    assert_select "h2", text: "Permanent bulk erasure"
    post credential_device_stream_path(@stream.stream_key)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match(/shd_[0-9a-f]{64}/, response.body)
    credential = @stream.device_stream_credentials.last
    get device_stream_path(@stream.stream_key)
    assert_no_match(/shd_[0-9a-f]{64}/, response.body)
    delete revoke_device_stream_path(@stream.stream_key), params: { credential_id: credential.to_param }
    assert credential.reload.revoked_at
    delete erase_session_device_stream_path(@stream.stream_key), params: { session_id: SecureRandom.uuid }
    assert @stream.device_stream_sessions.last.erased_at
    delete device_stream_path(@stream.stream_key)
    assert @stream.reload.erased_at
  end

  test "another account member cannot manage even with read grant" do
    user = users(:existing_user)
    @stream.configure!(user_ids: [ user.id ], agent_ids: [], enabled: true)
    sign_in(user)
    get device_stream_path(@stream.stream_key)
    assert_response :not_found
    post credential_device_stream_path(@stream.stream_key)
    assert_response :not_found
    delete device_stream_path(@stream.stream_key)
    assert_response :not_found
    assert_nil @stream.reload.erased_at
  end

  test "subject retains erasure after membership removal" do
    @account.memberships.find_by!(user: @subject).update_column(:confirmed_at, nil)
    delete device_stream_path(@stream.stream_key)
    assert_redirected_to device_stream_path(@stream.stream_key)
    assert @stream.reload.erased_at
  end

  test "stream index renders account selection and posts disabled creation" do
    get device_streams_path
    assert_response :success
    assert_select "select[name=account_id]"
    post device_streams_path, params: { account_id: @account.to_param, name: "From index" }
    assert_response :redirect
    assert_not DeviceStream.order(:id).last.enabled?
  end

end
