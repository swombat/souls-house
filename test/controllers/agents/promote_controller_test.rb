require "test_helper"
require "webmock/minitest"

class Agents::PromoteControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)

    sign_in @user
  end

  test "begin creates hosted sandbox metadata and enqueues promotion" do
    assert_difference "ApiKey.count", 1 do
      assert_enqueued_with(job: PromoteAgentJob) do
        post begin_promote_account_agent_path(@account, @agent)
      end
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "hosting")
    @agent.reload

    assert_equal "migrating", @agent.runtime
    assert_predicate @agent.uuid, :present?
    assert_equal Agents::Resources.new(@agent).container, @agent.container_name
    assert_equal Agents::Config.sandbox_host, @agent.sandbox_host
    assert_equal Agents::Config.default_image, @agent.container_image
    assert_predicate @agent.trigger_bearer_token, :present?
    assert_predicate @agent.outbound_api_token, :present?
    assert_predicate @agent.restic_password, :present?
    assert_not_nil @agent.migration_started_at
    assert_equal @agent, @agent.outbound_api_key.agent
  end

  test "begin refuses an already migrating agent" do
    key = ApiKey.generate_for(@user, name: "existing", agent: @agent)
    @agent.update!(
      runtime: "migrating",
      uuid: SecureRandom.uuid_v7,
      trigger_bearer_token: "tr_existing",
      outbound_api_key: key,
      outbound_api_token: key.raw_token,
      migration_started_at: Time.current
    )

    assert_no_difference "ApiKey.count" do
      assert_no_enqueued_jobs only: PromoteAgentJob do
        post begin_promote_account_agent_path(@account, @agent)
      end
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "hosting")
  end

  test "begin reports missing hosted runtime configuration without mutating agent" do
    original_runtime = @agent.runtime
    original_uuid = @agent.uuid
    original_container_name = @agent.container_name

    Agents::Config.stub(:internal_url, -> { raise KeyError, "HELIXKIT_AGENT_INTERNAL_URL is required" }) do
      assert_no_difference "ApiKey.count" do
        assert_no_enqueued_jobs only: PromoteAgentJob do
          post begin_promote_account_agent_path(@account, @agent)
        end
      end
    end

    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "hosting")
    assert_match "Hosted agent runtime is not configured", flash[:alert]
    @agent.reload
    assert_equal original_runtime, @agent.runtime
    assert_equal [ original_uuid, original_container_name ], [ @agent.uuid, @agent.container_name ]
  end

  test "cancel returns agent to inline and revokes scoped key" do
    key = ApiKey.generate_for(@user, name: "agent key", agent: @agent)
    @agent.update!(
      runtime: "migrating",
      uuid: SecureRandom.uuid_v7,
      trigger_bearer_token: "tr_existing",
      outbound_api_key: key,
      outbound_api_token: key.raw_token,
      restic_password: "restic",
      migration_started_at: Time.current
    )

    assert_difference "ApiKey.count", -1 do
      post cancel_promote_account_agent_path(@account, @agent)
    end

    @agent.reload
    assert_equal "inline", @agent.runtime
    assert_nil @agent.trigger_bearer_token
    assert_nil @agent.outbound_api_key
    assert_nil @agent.outbound_api_token
    assert_nil @agent.restic_password
    assert_nil @agent.migration_started_at
  end

  test "cancel does not demote a born-hosted agent" do
    key = ApiKey.generate_for(@user, name: "born agent key", agent: @agent)
    @agent.update!(
      runtime: "provisioning",
      birth_committed_at: Time.current,
      uuid: SecureRandom.uuid_v7,
      trigger_bearer_token: "tr_existing",
      outbound_api_key: key,
      outbound_api_token: key.raw_token,
      provisioning_started_at: Time.current
    )

    assert_no_difference "ApiKey.count" do
      post cancel_promote_account_agent_path(@account, @agent)
    end

    assert_redirected_to onboarding_account_agent_path(@account, @agent)
    assert_equal "provisioning", @agent.reload.runtime
    assert_equal key, @agent.outbound_api_key
  end

  test "send test request probes external runtime synchronously" do
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )
    trigger = stub_request(:post, "https://agent.example.com/trigger")
      .with(headers: { "Authorization" => "Bearer tr_valid" })
      .to_return(status: 200, body: { status: "accepted" }.to_json)

    post send_test_request_account_agent_path(@account, @agent)

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "runtime_reachable", json["status"]
    assert_predicate json["conversation_id"], :present?
    assert_requested trigger
  end

  test "send orientation probes external runtime and returns orientation status" do
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )
    fake_journal_status = Object.new
    def fake_journal_status.snapshot = {}
    def fake_journal_status.grown_since?(_before) = true
    trigger = stub_request(:post, "https://agent.example.com/trigger")
      .with(headers: { "Authorization" => "Bearer tr_valid" })
      .to_return(status: 200, body: { status: "ok", stdout: "oriented" }.to_json)

    Agents::DailyJournalStatus.stub :new, fake_journal_status do
      post send_orientation_account_agent_path(@account, @agent)
    end

    assert_response :success
    json = JSON.parse(response.body)
    assert_equal "orientation_sent", json["status"]
    assert_equal true, json["oriented"]
    assert_predicate @agent.reload.oriented_at, :present?
    assert_requested trigger
  end

  test "send orientation requires healthy external agent" do
    @agent.update!(runtime: "inline")

    post send_orientation_account_agent_path(@account, @agent)

    assert_response :unprocessable_entity
  end

end
