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

  test "the first failure stamps when the run began; recovery clears it" do
    stub_request(:get, "https://agent.example.com/health").to_return(status: 500)
    freeze_time do
      2.times { AgentHealthCheckJob.perform_now }
      @agent.reload
      assert_equal Time.current, @agent.health_failing_since
      assert_equal "unanswered", @agent.health_failure_kind
    end
    travel 10.minutes
    AgentHealthCheckJob.perform_now
    assert_equal 3, @agent.reload.consecutive_health_failures
    assert_equal 10.minutes.ago.to_i, @agent.health_failing_since.to_i

    stub_request(:get, "https://agent.example.com/health").to_return(status: 200, body: "{}")
    AgentHealthCheckJob.perform_now
    @agent.reload
    assert_nil @agent.health_failing_since
    assert_nil @agent.health_failure_kind
  end

  def with_restart_counts(*counts)
    @agent.update!(container_name: "sh-test-research-assistant")
    sandbox = Object.new
    sandbox.define_singleton_method(:restart_count) { counts.shift }
    Agents::Sandbox.stub(:new, sandbox) { yield }
  end

  test "a container that restarted since the last probe fails the check even when the probe passes" do
    stub_request(:get, "https://agent.example.com/health").to_return(status: 200, body: "{}")
    with_restart_counts(7, 7, 9) do
      2.times { AgentHealthCheckJob.perform_now }
      assert_equal "healthy", @agent.reload.health_state
      assert_equal 7, @agent.runtime_restart_count
      AgentHealthCheckJob.perform_now
    end
    @agent.reload
    assert_equal "unhealthy", @agent.health_state
    assert_equal "restarting", @agent.health_failure_kind
    assert_equal 1, @agent.consecutive_health_failures
    assert_equal 9, @agent.runtime_restart_count
  end

  test "a recreated container starts a fresh baseline, and no count at all is no verdict" do
    stub_request(:get, "https://agent.example.com/health").to_return(status: 200, body: "{}")
    with_restart_counts(12, 0, nil) do
      3.times { AgentHealthCheckJob.perform_now }
    end
    @agent.reload
    assert_equal "healthy", @agent.health_state
    assert_equal 0, @agent.consecutive_health_failures
    assert_equal 0, @agent.runtime_restart_count
  end

  test "the restart count is not asked of a resident with no container" do
    stub_request(:get, "https://agent.example.com/health").to_return(status: 200, body: "{}")
    Agents::Sandbox.stub(:new, ->(*) { raise "docker was asked" }) do
      AgentHealthCheckJob.perform_now
    end
    assert_equal "healthy", @agent.reload.health_state
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
