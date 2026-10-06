require "test_helper"
require "webmock/minitest"
require_relative "../support/github_import_fixtures"

class AgentHealthCheckJobTest < ActiveJob::TestCase

  include GithubImportFixtures

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      endpoint_url: "https://agent.example.com",
      trigger_bearer_token: "tr_valid",
      health_state: "healthy",
      consecutive_health_failures: 0
    )
  end

  test "marks external agent unhealthy and offline after repeated failures" do
    stub_request(:get, "https://agent.example.com/health").to_return(status: 500)

    6.times { AgentHealthCheckJob.perform_now }

    @agent.reload
    assert_equal "offline", @agent.runtime
    assert_equal "unhealthy", @agent.health_state
    assert_equal 6, @agent.consecutive_health_failures
    assert_not_nil @agent.last_health_check_at
  end

  test "returns offline agent to external after successful health check" do
    @agent.update!(runtime: "offline", health_state: "unhealthy", consecutive_health_failures: 6)
    stub_request(:get, "https://agent.example.com/health").to_return(status: 200, body: "{}")

    AgentHealthCheckJob.perform_now

    @agent.reload
    assert_equal "external", @agent.runtime
    assert_equal "healthy", @agent.health_state
    assert_equal 0, @agent.consecutive_health_failures
  end

  test "does not mark an intentionally cold development container unhealthy" do
    sandbox = Object.new
    sandbox.define_singleton_method(:stopped?) { true }

    Agents::Config.stub(:cold_start?, true) do
      Agents::Sandbox.stub(:new, sandbox) do
        AgentHealthCheckJob.perform_now
      end
    end

    @agent.reload
    assert_equal "external", @agent.runtime
    assert_equal "healthy", @agent.health_state
    assert_equal 0, @agent.consecutive_health_failures
    assert_nil @agent.last_health_check_at
  end

  test "records only standard sync safe status without raw errors" do
    request = import_request(account: @agent.account, connection: import_connection(account: @agent.account), sync_strategy: "standard")
    @agent.update_columns(github_resident_import_id: request.id)
    stub_request(:get, "https://agent.example.com/health").to_return(status: 200, body: {
      home_sync: { state: "needs_attention", reason_code: "merge_conflict", rescue_status: "failed",
        checked_at: Time.current.iso8601, last_error: "PRIVATE LOG" }
    }.to_json)
    AgentHealthCheckJob.perform_now
    assert_equal "needs_attention", request.reload.sync_health_props["state"]
    assert_equal "failed", request.sync_health_props["rescue_status"]
    assert_not_includes request.sync_health.to_json, "PRIVATE"
    stub_request(:get, "https://agent.example.com/health").to_return(status: 500)
    AgentHealthCheckJob.perform_now
    assert_equal "runtime_unavailable", request.reload.sync_health_props["reason_code"]
  end

end
