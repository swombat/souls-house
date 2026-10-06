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

  test "deleted sessions stay stored but vanish from latest and discovery" do
    kept = @payload.merge(session_id: SecureRandom.uuid)
    post @samples, params: @payload, as: :json, headers: bearer(@device_token)
    post @samples, params: kept, as: :json, headers: bearer(@device_token)
    @stream.erase_session!(@payload[:session_id])
    assert_equal 2, @stream.device_stream_batches.count
    get @latest, headers: bearer(@reader_token)
    assert_equal [ kept[:session_id] ], response.parsed_body["batches"].map { |batch| batch["session_id"] }
    get "/api/v1/streams/#{@stream.stream_key}/sessions", headers: bearer(@reader_token)
    assert_equal [ kept[:session_id] ], response.parsed_body["sessions"].map { |session| session["session_id"] }
  end

  test "session read hides samples when deletion lands between lookup and payload query" do
    post @samples, params: @payload, as: :json, headers: bearer(@device_token)
    stream = @stream
    uuid = @payload[:session_id]
    deleted = false
    callback = lambda do |*, payload|
      next if deleted || payload[:name] == "SCHEMA"
      next unless payload[:sql].include?("device_stream_sessions") && payload[:sql].include?("session_uuid")
      deleted = true
      DeviceStream.find(stream.id).erase_session!(uuid)
    end
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get session_path, headers: bearer(@reader_token)
    end
    assert deleted, "deletion hook never fired"
    assert_response :ok
    assert_empty response.parsed_body["batches"]
    assert_equal 1, @stream.device_stream_batches.count
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

  test "historical session pages preserve RR precision and isolate sessions" do
    session = @stream.device_stream_sessions.create!(session_uuid: @payload[:session_id])
    201.times do |i|
      session.device_stream_batches.create!(sequence: i * 2, observed_at: 1.day.ago, rr_ms: [ 810.546875 ], payload_digest: "synthetic")
    end
    other = @stream.device_stream_sessions.create!(session_uuid: SecureRandom.uuid)
    other.device_stream_batches.create!(sequence: 1, observed_at: 1.day.ago, rr_ms: [ 999 ], payload_digest: "synthetic")
    get session_path, headers: bearer(@reader_token)
    assert_response :ok
    body = response.parsed_body
    assert_equal 200, body["batches"].size
    assert_equal (0...200).map { |i| i * 2 }, body["batches"].pluck("sequence")
    assert_equal "398", body["next_cursor"]
    assert_equal [ 810.546875 ], body["batches"].first["rr_ms"]
    assert_equal @payload[:session_id], body["session_id"]
    assert_equal "no-store", response.headers["Cache-Control"]
    get session_path, params: { cursor: body["next_cursor"] }, headers: bearer(@reader_token)
    assert_response :ok
    assert_equal [ 400 ], response.parsed_body["batches"].pluck("sequence")
    assert_nil response.parsed_body["next_cursor"]
  end

  test "session reads recheck explicit agent grants and account scope" do
    @stream.device_stream_sessions.create!(session_uuid: @payload[:session_id])
    agent = agents(:other_account_agent)
    token = ApiKey.generate_for(@subject, agent: agent, name: "Session reader").raw_token
    get session_path, headers: bearer(token)
    assert_response :not_found
    @stream.configure!(user_ids: [], agent_ids: [ agent.id ], enabled: true)
    get session_path, headers: bearer(token)
    assert_response :ok
    assert_empty response.parsed_body["batches"]
    @stream.configure!(user_ids: [], agent_ids: [], enabled: true)
    get session_path, params: { cursor: "0" }, headers: bearer(token)
    assert_response :not_found
    wrong_account = ApiKey.generate_for(@subject, account: accounts(:personal_account), name: "Wrong account").raw_token
    get session_path, headers: bearer(wrong_account)
    assert_response :not_found
    get session_path, headers: bearer(@device_token)
    assert_response :unauthorized
  end

  test "session reads reject malformed cursors and hide erased or foreign sessions" do
    @stream.device_stream_sessions.create!(session_uuid: @payload[:session_id])
    [ "", "-1", "01", "1.0", "9007199254740992", "x", [ "1" ] ].each do |cursor|
      get session_path, params: { cursor: cursor }, headers: bearer(@reader_token)
      assert_response :unprocessable_entity
      assert_equal "no-store", response.headers["Cache-Control"]
    end
    get session_path, params: { cursor: "9007199254740991" }, headers: bearer(@reader_token)
    assert_response :ok
    assert_empty response.parsed_body["batches"]
    other_stream = DeviceStream.create!(account: @account, subject_user: @subject, name: "Other")
    foreign = other_stream.device_stream_sessions.create!(session_uuid: SecureRandom.uuid)
    get "/api/v1/streams/#{@stream.stream_key}/sessions/#{foreign.session_uuid}", headers: bearer(@reader_token)
    assert_response :not_found
    @stream.erase_session!(@payload[:session_id])
    get session_path, headers: bearer(@reader_token)
    assert_response :not_found
    assert_equal "no-store", response.headers["Cache-Control"]
    @stream.erase!
    get session_path, headers: bearer(@reader_token)
    assert_response :not_found
  end

  test "discovery lists bounded metadata by observation time not upload order" do
    base = 2.days.ago.change(usec: 0)
    uuids = 51.times.map do |i|
      session = @stream.device_stream_sessions.create!(session_uuid: SecureRandom.uuid)
      session.device_stream_batches.create!(sequence: 0, observed_at: base + i.minutes,
                                            rr_ms: [ 810.546875 ], payload_digest: "synthetic")
      session.session_uuid
    end
    newest = @stream.device_stream_sessions.find_by!(session_uuid: uuids.last)
    newest.device_stream_batches.create!(sequence: 1, observed_at: base - 1.minute,
                                         rr_ms: [ 800 ], payload_digest: "synthetic")
    @stream.device_stream_sessions.create!(session_uuid: SecureRandom.uuid)
    get sessions_path, headers: bearer(@reader_token)
    assert_response :ok
    body = response.parsed_body
    assert_equal true, body["truncated"]
    assert_equal uuids.reverse.first(50), body["sessions"].pluck("session_id")
    assert_equal %w[batch_count first_observed_at last_observed_at session_id], body["sessions"].first.keys.sort
    assert_equal 2, body["sessions"].first["batch_count"]
    assert_equal (base - 1.minute).iso8601(6), body["sessions"].first["first_observed_at"]
    assert_equal (base + 50.minutes).iso8601(6), body["sessions"].first["last_observed_at"]
    assert_equal "no-store", response.headers["Cache-Control"]
    @stream.erase_session!(uuids.last)
    get sessions_path, headers: bearer(@reader_token)
    assert_equal false, response.parsed_body["truncated"]
    assert_equal uuids[0...-1].reverse, response.parsed_body["sessions"].pluck("session_id")
  end

  test "discovery rechecks reader grants rejects device and wrong account and hides erased streams" do
    agent = agents(:other_account_agent)
    token = ApiKey.generate_for(@subject, agent: agent, name: "Discovery reader").raw_token
    get sessions_path, headers: bearer(token)
    assert_response :not_found
    @stream.configure!(user_ids: [], agent_ids: [ agent.id ], enabled: true)
    get sessions_path, headers: bearer(token)
    assert_response :ok
    assert_equal [], response.parsed_body["sessions"]
    assert_equal false, response.parsed_body["truncated"]
    @stream.configure!(user_ids: [], agent_ids: [], enabled: true)
    get sessions_path, headers: bearer(token)
    assert_response :not_found
    get sessions_path, headers: bearer(@device_token)
    assert_response :unauthorized
    wrong_account = ApiKey.generate_for(@subject, account: accounts(:personal_account), name: "Wrong account").raw_token
    get sessions_path, headers: bearer(wrong_account)
    assert_response :not_found
    @stream.erase!
    get sessions_path, headers: bearer(@reader_token)
    assert_response :not_found
    assert_equal "no-store", response.headers["Cache-Control"]
  end

  private

  def sessions_path
    "/api/v1/streams/#{@stream.stream_key}/sessions"
  end

  def session_path
    "/api/v1/streams/#{@stream.stream_key}/sessions/#{@payload[:session_id]}"
  end

  def bearer(token)
    { "Authorization" => "Bearer #{token}" }
  end

end
