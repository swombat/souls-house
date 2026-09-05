require "test_helper"
require "webmock/minitest"

class Agents::RuntimeChecksControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external", uuid: SecureRandom.uuid_v7, endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid", health_state: "healthy", consecutive_health_failures: 0
    )
    sign_in @user
  end

  test "test request probes the existing external runtime" do
    trigger = stub_request(:post, "https://agent.example.com/trigger")
      .with(headers: { "Authorization" => "Bearer tr_valid" })
      .to_return(status: 200, body: { status: "accepted" }.to_json)

    post send_test_request_account_agent_path(@account, @agent)
    assert_response :success
    assert_equal "runtime_reachable", response.parsed_body["status"]
    assert response.parsed_body["conversation_id"].present?
    assert_requested trigger
  end

  test "orientation retains journal verification for an existing promoted resident" do
    journal = Object.new
    def journal.snapshot = {}
    def journal.grown_since?(_before) = true
    trigger = stub_request(:post, "https://agent.example.com/trigger")
      .with(headers: { "Authorization" => "Bearer tr_valid" })
      .to_return(status: 200, body: { status: "ok", stdout: "oriented" }.to_json)

    Agents::DailyJournalStatus.stub(:new, journal) do
      post send_orientation_account_agent_path(@account, @agent)
    end
    assert_response :success
    assert_equal "orientation_sent", response.parsed_body["status"]
    assert response.parsed_body["oriented"]
    assert @agent.reload.oriented_at
    assert_nil @agent.birth_committed_at
    assert_requested trigger
  end

  test "deprecated residents cannot be probed or oriented" do
    @agent.update_columns(runtime: "deprecated")
    assert_no_difference [ "Chat.count", "Message.count", "ApiKey.count" ] do
      post send_test_request_account_agent_path(@account, @agent)
      assert_response :conflict
      post send_orientation_account_agent_path(@account, @agent)
      assert_response :unprocessable_entity
    end
    assert_not_requested :post, "https://agent.example.com/trigger"
  end

  test "promotion and tool execution routes are retired" do
    helpers = Rails.application.routes.url_helpers
    %i[begin_promote_account_agent_path cancel_promote_account_agent_path promote_account_agent_path
       account_agent_refinement_path account_agent_initiation_path message_hallucination_fix_path].each do |helper|
      assert_not helpers.respond_to?(helper), helper
    end
  end

end
