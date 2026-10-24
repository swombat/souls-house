require "test_helper"

class Api::V1::CompanionOperationsTest < ActionDispatch::IntegrationTest

  include ActionCable::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @key = ApiKey.generate_for(users(:user_1), name: "Fixture", agent: @agent)
    grant = CompanionEnrollmentGrant.create!(account: @agent.account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Fixture", device_request_id: "fixture",
      policy: { "residents" => [ { "id" => @agent.obfuscated_id,
        "volumes" => [ { "volume" => "fixture-volume", "access" => "read" } ], "execute" => false } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), "fixture")
    @device.update!(connection_epoch: "epoch")
  end

  test "resident dispatches read and device-only HTTP body returns to its originating actor" do
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "read", arguments: { volume: "fixture-volume", path: "fixture" } },
      headers: bearer(@key.raw_token), as: :json
    assert_response :accepted
    id = response.parsed_body.fetch("id")
    post "/api/v1/companion/operations/#{id}/result", params: "fixture bytes",
      headers: bearer(@credential).merge("CONTENT_TYPE" => "application/octet-stream",
        "X-Companion-Epoch" => "epoch", "X-Companion-Revision" => "1", "X-Companion-Format" => "binary")
    assert_response :created
    get "/api/v1/companion_devices/#{@device.to_param}/operations/#{id}/body", headers: bearer(@key.raw_token)
    assert_response :success
    assert_equal "fixture bytes", response.body
    get "/api/v1/companion_devices/#{@device.to_param}/operations/#{id}/body", headers: bearer(@key.raw_token)
    assert_response :gone
  end

  test "device can only revoke itself including paused and repeat removal" do
    post "/api/v1/companion/revoke", headers: bearer(@key.raw_token)
    assert_response :unauthorized
    assert_nil @device.reload.revoked_at
    @device.update!(paused: true)
    assert_difference -> { AuditLog.where(action: "companion.device.revoked").count }, 1 do
      post "/api/v1/companion/revoke", headers: bearer(@credential)
      assert_response :no_content
      post "/api/v1/companion/revoke", headers: bearer(@credential)
      assert_response :no_content
    end
    assert @device.reload.revoked_at
    assert_nil CompanionDevice.authenticate(@credential)
  end

  test "device uploads an empty raw error result without storing a body" do
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "stat",
      arguments: { "volume" => "fixture-volume", "path" => "protected-fixture" })
    operation.dispatch!

    post "/api/v1/companion/operations/#{operation.to_param}/result", params: "",
      headers: bearer(@credential).merge("CONTENT_TYPE" => "application/octet-stream",
        "X-Companion-Epoch" => "epoch", "X-Companion-Revision" => "1",
        "X-Companion-Format" => "json", "X-Companion-Error" => "denied")

    assert_response :created
    assert_equal "failed", operation.reload.state
    assert_equal "denied", operation.outcome
    assert_nil operation.body
    get "/api/v1/companion_devices/#{@device.to_param}/operations/#{operation.to_param}/body",
      headers: bearer(@key.raw_token)
    assert_response :gone
  end

  test "device uploads a successful empty raw read result for single use delivery" do
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "read",
      arguments: { "volume" => "fixture-volume", "path" => "empty-fixture" })
    operation.dispatch!

    post "/api/v1/companion/operations/#{operation.to_param}/result", params: "",
      headers: bearer(@credential).merge("CONTENT_TYPE" => "application/octet-stream",
        "X-Companion-Epoch" => "epoch", "X-Companion-Revision" => "1", "X-Companion-Format" => "binary")

    assert_response :created
    assert_equal "completed", operation.reload.state
    assert_equal "ok", operation.outcome
    assert_equal "", operation.body.data
    path = "/api/v1/companion_devices/#{@device.to_param}/operations/#{operation.to_param}/body"
    get path, headers: bearer(@key.raw_token)
    assert_response :success
    assert_equal "", response.body
    get path, headers: bearer(@key.raw_token)
    assert_response :gone
  end

  test "previous device credential is not removal authority" do
    result = CompanionDevice.create_session!(@credential, "rotation-fixture")
    post "/api/v1/companion/revoke", headers: bearer(@credential)
    assert_response :unauthorized
    assert_nil @device.reload.revoked_at
    post "/api/v1/companion/revoke", headers: bearer(result.fetch("device_credential"))
    assert_response :no_content
  end

  test "device credential cannot call resident APIs and resident bearer cannot upload device results" do
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "drives", arguments: {} }, headers: bearer(@credential), as: :json
    assert_response :unauthorized
    post "/api/v1/companion/operations/not-an-id/result", params: "fixture",
      headers: bearer(@key.raw_token).merge("CONTENT_TYPE" => "application/octet-stream")
    assert_response :unauthorized
  end

  test "missing arguments is valid for discovery but scalar arguments is rejected" do
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "drives" }, headers: bearer(@key.raw_token), as: :json
    assert_response :accepted
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "read", arguments: "not-an-object" }, headers: bearer(@key.raw_token), as: :json
    assert_response :unprocessable_entity
  end

  test "human owner can pause resume and revoke but resident cannot control the device" do
    path = "/api/v1/companion_devices/#{@device.to_param}"
    patch path, params: { account_id: @agent.account.to_param, control: "pause" },
      headers: bearer(@key.raw_token), as: :json
    assert_response :forbidden
    human = ApiKey.generate_for(users(:user_1), name: "Fixture owner", account: @agent.account)
    %w[pause resume revoke].each do |control|
      patch path, params: { account_id: @agent.account.to_param, control: control },
        headers: bearer(human.raw_token), as: :json
      assert_response :no_content
      internal = "action_cable/#{@device.to_gid_param}"
      if control == "resume"
        assert_no_broadcasts internal
      else
        assert_broadcast_on internal, { type: "disconnect", reconnect: false }
      end
      pubsub_adapter.clear
      @device.reload
      assert_equal control == "pause", @device.paused? unless control == "revoke"
    end
    assert @device.revoked_at
    assert_nil CompanionDevice.authenticate(@credential)
  end

  test "write upload is actor scoped and only the device consumes its dispatched input once" do
    enroll_mutation_fixture
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "write", arguments: { volume: "fixture-volume", path: "fixture", input_size: 7 } },
      headers: bearer(@key.raw_token), as: :json
    assert_response :accepted
    id = response.parsed_body.fetch("id")
    operation = CompanionOperation.find(id)
    assert_equal "pending", operation.state
    input_path = "/api/v1/companion_devices/#{@device.to_param}/operations/#{id}/input"
    put input_path, params: "PRIVATE", headers: bearer(@credential).merge("CONTENT_TYPE" => "application/octet-stream")
    assert_response :unauthorized
    other_key = ApiKey.generate_for(users(:user_1), name: "Other fixture", agent: agents(:code_reviewer))
    put input_path, params: "PRIVATE", headers: bearer(other_key.raw_token).merge("CONTENT_TYPE" => "application/octet-stream")
    assert_response :not_found
    assert_nil operation.reload.input
    put input_path, params: "PRIVATE", headers: bearer(@key.raw_token).merge("CONTENT_TYPE" => "application/octet-stream")
    assert_response :created
    assert_equal "dispatched", operation.reload.state
    get "/api/v1/companion/operations/#{id}/input", headers: bearer(@key.raw_token)
    assert_response :unauthorized
    device_headers = bearer(@credential).merge("X-Companion-Epoch" => "epoch", "X-Companion-Revision" => "1")
    get "/api/v1/companion/operations/#{id}/input", headers: device_headers.merge("X-Companion-Epoch" => "other")
    assert_response :gone
    get "/api/v1/companion/operations/#{id}/input", headers: device_headers
    assert_response :success
    assert_equal "PRIVATE", response.body
    get "/api/v1/companion/operations/#{id}/input", headers: device_headers
    assert_response :gone
  end

  test "empty write input dispatches and is consumed only once" do
    enroll_mutation_fixture
    post "/api/v1/companion_devices/#{@device.to_param}/operations",
      params: { operation: "write", arguments: { volume: "fixture-volume", path: "empty-fixture", input_size: 0 } },
      headers: bearer(@key.raw_token), as: :json
    assert_response :accepted
    id = response.parsed_body.fetch("id")
    input_path = "/api/v1/companion_devices/#{@device.to_param}/operations/#{id}/input"
    headers = bearer(@key.raw_token).merge("CONTENT_TYPE" => "application/octet-stream")
    put input_path, params: "", headers: headers
    assert_response :created
    operation = CompanionOperation.find(id)
    assert_equal "dispatched", operation.state
    assert_equal "", operation.input.data
    put input_path, params: "", headers: headers
    assert_response :conflict
    device_headers = bearer(@credential).merge("X-Companion-Epoch" => "epoch", "X-Companion-Revision" => "1")
    get "/api/v1/companion/operations/#{id}/input", headers: device_headers
    assert_response :success
    assert_equal "", response.body
    get "/api/v1/companion/operations/#{id}/input", headers: device_headers
    assert_response :gone
  end

  test "execute result is HTTP bounded rather than the inline JSON limit" do
    enroll_mutation_fixture(execute: true)
    input = '{"argv":["/usr/bin/true"],"cwd":"/"}'
    operation = CompanionOperation.start!(device: @device, agent: @agent, kind: "execute",
      arguments: { "input_size" => input.bytesize, "timeout_seconds" => 300 })
    operation.attach_input!(input)
    operation.dispatch!
    data = { stdout_base64: "eA==" * 20_000, stderr_base64: "", exit_code: 0 }.to_json
    assert_operator data.bytesize, :>, CompanionOperation::MAX_INLINE
    post "/api/v1/companion/operations/#{operation.to_param}/result", params: data,
      headers: bearer(@credential).merge("CONTENT_TYPE" => "application/octet-stream",
        "X-Companion-Epoch" => "epoch", "X-Companion-Revision" => "1", "X-Companion-Format" => "json")
    assert_response :created
    assert_equal "completed", operation.reload.state
  end

  private

  def enroll_mutation_fixture(execute: false)
    request_id = SecureRandom.hex(12)
    grant = CompanionEnrollmentGrant.create!(account: @agent.account, minting_agent: @agent,
      created_by_user: users(:user_1), name: "Mutation fixture", device_request_id: request_id,
      policy: { "residents" => [ { "id" => @agent.obfuscated_id, "execute" => execute,
        "volumes" => [ { "volume" => "fixture-volume", "access" => "write" } ] } ] },
      expires_at: 1.hour.from_now)
    @device, @credential = CompanionEnrollmentGrant.enroll!(grant.issue_token!(@agent), request_id)
    @device.update!(connection_epoch: "epoch")
  end

  def bearer(value)
    { "Authorization" => "Bearer #{value}" }
  end

end
