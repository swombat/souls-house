require "test_helper"
require "webmock/minitest"

class ExternalAgentWakeJobTest < ActiveJob::TestCase

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
    # Scheduled runs are refused before dispatch without a usable credential
    # (InferenceAvailability); fund the route so the trigger itself is tested.
    @agent.account.update!(openrouter_api_key: "test-router")
  end

  test "sends scheduled wake invitations to external agents" do
    request = stub_request(:post, "https://agent.example.com/trigger")
      .with(
        headers: { "Authorization" => "Bearer tr_valid" },
        body: lambda { |body|
          parsed = JSON.parse(body)
          parsed["trigger_kind"] == "wake" &&
            parsed["conversation_id"].nil? &&
            parsed["session_id"] == "#{@agent.uuid}-wake" &&
            parsed["request"].include?("scheduled self-directed session")
        }
      )
      .to_return(status: 200, body: { status: "ok" }.to_json)

    travel_to Time.utc(2026, 1, 28, 12, 5, 0) do
      ExternalAgentWakeJob.perform_now
    end

    assert_requested request
  end

  test "skips agents whose account is disabled" do
    @agent.update_columns(name: "Claude")
    @agent.account.disable!
    request = stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 200, body: { status: "ok" }.to_json)

    travel_to Time.utc(2026, 1, 28, 12, 5, 0) do
      ExternalAgentWakeJob.perform_now
    end

    assert_not_requested request
  end

  test "sends hourly wake invitations to Claude" do
    @agent.update_columns(name: "Claude")
    request = stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 200, body: { status: "ok" }.to_json)

    travel_to Time.utc(2026, 1, 28, 12, 5, 0) do
      ExternalAgentWakeJob.perform_now
    end

    assert_requested request
  end

  test "does not send scheduled wakes to agents with heartbeats disabled" do
    @agent.update!(scheduled_wakes_enabled: false, heartbeat_wakes_per_day: 48)

    ExternalAgentWakeJob.perform_now

    assert_not_requested :post, "https://agent.example.com/trigger"
  end

  test "persistent wake mode reuses the stable wake session" do
    @agent.update!(persistent_wake_session: true)
    request = stub_request(:post, "https://agent.example.com/trigger")
      .with(body: lambda { |body|
        parsed = JSON.parse(body)
        parsed["persistent_session"] == true &&
          parsed["session_id"] == "#{@agent.uuid}-wake"
      })
      .to_return(status: 200, body: { status: "ok" }.to_json)

    travel_to Time.utc(2026, 1, 28, 12, 5, 0) do
      ExternalAgentWakeJob.perform_now
    end

    assert_requested request
  end

  test "only sends the configured number of daily wakes" do
    @agent.update!(heartbeat_wakes_per_day: 2)
    request = stub_request(:post, "https://agent.example.com/trigger")
      .to_return(status: 200, body: { status: "ok" }.to_json)

    travel_to Time.utc(2026, 1, 28, 6, 5, 0) do
      ExternalAgentWakeJob.perform_now
    end
    assert_not_requested request

    [ 0, 12 ].each do |hour|
      travel_to Time.utc(2026, 1, 28, hour, 5, 0) do
        ExternalAgentWakeJob.perform_now
      end
    end

    assert_requested request, times: 2
  end

  test "does not wake offline agents" do
    @agent.update!(runtime: "offline")

    travel_to Time.utc(2026, 1, 28, 12, 5, 0) do
      ExternalAgentWakeJob.perform_now
    end

    assert_not_requested :post, "https://agent.example.com/trigger"
  end

end
