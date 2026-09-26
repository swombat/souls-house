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
    assert_redirected_to account_device_stream_path(@account, stream.stream_key)
    assert_equal @subject, stream.subject_user
    assert_not stream.enabled?
    assert_empty stream.reader_agent_ids
    patch account_device_stream_path(@account, stream.stream_key), params: { enabled: "1", reader_agent_ids: [ agents(:other_account_agent).to_param ] }
    assert_redirected_to account_device_stream_path(@account, stream.stream_key)
    assert_equal [ agents(:other_account_agent).id ], stream.reload.reader_agent_ids
  end

  test "browser controls expose revoke erase and one-time credential" do
    get account_device_stream_path(@account, @stream.stream_key)
    assert_response :success
    assert_select "h2", text: "Permanent bulk erasure"
    post credential_account_device_stream_path(@account, @stream.stream_key)
    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_match(/shd_[0-9a-f]{64}/, response.body)
    credential = @stream.device_stream_credentials.last
    get account_device_stream_path(@account, @stream.stream_key)
    assert_no_match(/shd_[0-9a-f]{64}/, response.body)
    delete revoke_account_device_stream_path(@account, @stream.stream_key), params: { credential_id: credential.to_param }
    assert credential.reload.revoked_at
    delete erase_session_account_device_stream_path(@account, @stream.stream_key), params: { session_id: SecureRandom.uuid }
    assert @stream.device_stream_sessions.last.erased_at
    delete account_device_stream_path(@account, @stream.stream_key)
    assert @stream.reload.erased_at
  end

  test "another account member cannot manage even with read grant" do
    user = users(:existing_user)
    @stream.configure!(user_ids: [ user.id ], agent_ids: [], enabled: true)
    sign_in(user)
    get device_stream_path(@stream.stream_key)
    assert_response :not_found
    post credential_account_device_stream_path(@account, @stream.stream_key)
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

  test "stream index is bound to the selected account without an account picker" do
    other = DeviceStream.create!(account: accounts(:personal_account), subject_user: @subject, name: "Other account stream")
    get account_device_streams_path(@account)
    assert_response :success
    assert_select "h1", text: "Device streams — #{@account.name}"
    assert_select "select[name=account_id]", count: 0
    assert_select "form[action=?]", account_device_streams_path(@account)
    assert_select "a[href=?]", account_device_stream_path(@account, @stream.stream_key)
    assert_no_match other.name, response.body
    post account_device_streams_path(@account), params: { name: "From index" }
    assert_response :redirect
    assert_not DeviceStream.order(:id).last.enabled?
  end

  test "account controls reject stream keys from another account" do
    path = account_device_stream_path(accounts(:personal_account), @stream.stream_key)
    get path
    assert_response :not_found
    patch path, params: { enabled: "0" }
    assert_response :not_found
    delete path
    assert_response :not_found
    assert_nil @stream.reload.erased_at
  end

  test "reader controls show only residents of the stream account" do
    get account_device_stream_path(@account, @stream.stream_key)
    assert_select "input[name=?][value=?]", "reader_agent_ids[]", agents(:other_account_agent).to_param
    assert_select "input[name=?][value=?]", "reader_agent_ids[]", agents(:research_assistant).to_param, count: 0
    patch account_device_stream_path(@account, @stream.stream_key),
      params: { enabled: "1", reader_agent_ids: [ agents(:research_assistant).to_param ] }
    assert_response :unprocessable_entity
    assert_empty @stream.reload.reader_agent_ids
  end

  test "recovery stays available after membership loss but cannot configure or issue credentials" do
    token = @stream.issue_credential!
    credential = DeviceStreamCredential.authenticate(token)
    @account.memberships.find_by!(user: @subject).update_column(:confirmed_at, nil)
    get account_device_streams_path(@account)
    assert_response :not_found
    post credential_account_device_stream_path(@account, @stream.stream_key)
    assert_response :not_found
    get device_streams_path
    assert_response :success
    assert_select "a[href=?]", device_stream_path(@stream.stream_key)
    assert_select "form", count: 0
    get device_stream_path(@stream.stream_key)
    assert_response :success
    assert_select "input[name=?]", "reader_agent_ids[]", count: 0
    assert_select "form[action*=?]", "/credential", count: 0
    assert_no_match agents(:other_account_agent).name, response.body
    delete revoke_device_stream_path(@stream.stream_key), params: { credential_id: credential.to_param }
    assert credential.reload.revoked_at
    delete erase_session_device_stream_path(@stream.stream_key), params: { session_id: SecureRandom.uuid }
    assert @stream.device_stream_sessions.last.erased_at
    delete device_stream_path(@stream.stream_key)
    assert @stream.reload.erased_at
  end

end
