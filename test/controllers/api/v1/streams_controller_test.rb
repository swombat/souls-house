require "test_helper"

class Api::V1::StreamsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @subject = users(:user_1)
    @account = accounts(:team_account)
    @stream = DeviceStream.create!(account: @account, subject_user: @subject, name: "Synthetic")
    @device_token = @stream.issue_credential!
    @reader_token = ApiKey.generate_for(@subject, account: @account, name: "Test reader").raw_token
    @payload = { schema: "rr.v1", session_id: SecureRandom.uuid, sequence: 0, observed_at: Time.current.iso8601(6), rr_ms: [ 810.546875 ] }
    @samples = "/api/v1/streams/#{@stream.stream_key}/samples"
    @latest = "/api/v1/streams/#{@stream.stream_key}/latest"
  end

  test "post replay conflict and bounded read" do
    post @samples, params: @payload, as: :json, headers: bearer(@device_token)
    assert_response :created
    post @samples, params: @payload, as: :json, headers: bearer(@device_token)
    assert_response :ok
    post @samples, params: @payload.merge(rr_ms: [ 900 ]), as: :json, headers: bearer(@device_token)
    assert_response :conflict
    get @latest, headers: bearer(@reader_token)
    assert_response :ok
    assert_equal [ 810.546875 ], response.parsed_body["batches"].first["rr_ms"]
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  test "device cannot read or use existing APIs and agent keys cannot append" do
    get @latest, headers: bearer(@device_token)
    assert_response :unauthorized
    get api_v1_conversations_path, headers: bearer(@device_token)
    assert_response :unauthorized
    post @samples, params: @payload, as: :json, headers: bearer(@reader_token)
    assert_response :unauthorized
    post "/api/v1/streams/wrong/samples", params: @payload, as: :json, headers: bearer(@device_token)
    assert_response :unauthorized
  end

  test "agent owned by subject needs separate read grant" do
    agent = agents(:other_account_agent)
    token = ApiKey.generate_for(@subject, agent: agent, name: "Agent reader").raw_token
    get @latest, headers: bearer(token)
    assert_response :not_found
    @stream.configure!(user_ids: [], agent_ids: [ agent.id ], enabled: true)
    get @latest, headers: bearer(token)
    assert_response :success
    @stream.configure!(user_ids: [], agent_ids: [], enabled: true)
    get @latest, headers: bearer(token)
    assert_response :not_found
  end

  test "account scope is enforced even for the subject" do
    token = ApiKey.generate_for(@subject, account: accounts(:personal_account), name: "Wrong account").raw_token
    get @latest, headers: bearer(token)
    assert_response :not_found
  end

  test "revoked devices and erased sessions fail closed" do
    @stream.erase_session!(@payload[:session_id])
    post @samples, params: @payload, as: :json, headers: bearer(@device_token)
    assert_response :gone
    @stream.revoke_credential!(@stream.device_stream_credentials.first.id)
    post @samples, params: @payload, as: :json, headers: bearer(@device_token)
    assert_response :unauthorized
  end

  test "late historical uploads do not displace observed latest data" do
    post @samples, params: @payload, as: :json, headers: bearer(@device_token)
    post @samples, params: @payload.merge(sequence: 1, observed_at: 1.day.ago.iso8601), as: :json, headers: bearer(@device_token)
    assert_response :created
    get @latest, headers: bearer(@reader_token)
    assert_equal [ 0 ], response.parsed_body["batches"].map { |batch| batch["sequence"] }
  end

  test "oversized and extra fields rejected" do
    post @samples, params: @payload.merge(extra: "x" * 17_000), as: :json, headers: bearer(@device_token)
    assert_response :payload_too_large
    post @samples, params: @payload.merge(extra: 1), as: :json, headers: bearer(@device_token)
    assert_response :unprocessable_entity
    assert_empty @stream.device_stream_batches
  end

  private

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

end
