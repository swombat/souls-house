require "test_helper"

class Visits::PollerTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  class FakeClient
    attr_reader :completed_wakes

    def initialize(responses)
      @responses = responses
      @completed_wakes = []
    end

    def claim_wakes(_visit)
      @responses.shift
    end

    def complete_wake(_visit, wake_id:, status: nil)
      @completed_wakes << wake_id
      Visits::Client::Response.new(status: 200, body: "{}", json: {}, content_type: "application/json", content_disposition: nil)
    end
  end

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(
      active: true,
      paused: false,
      runtime: "external",
      trigger_bearer_token: "trigger_secret"
    )
    @visit = @agent.visits.create!(
      visited_origin: "https://other.souls.house",
      visited_account_name: "Nexus",
      local_name: "Reed",
      visit_token: "vst_secret_123",
      max_wakes_per_hour: 5
    )
  end

  test "enqueues a new wake once and never starts a second turn on redelivery" do
    wakes_payload = [ { "id" => "wake_1", "conversation_id" => "conv_1", "message_id" => "msg_1", "reason" => "mention" } ]
    ok = Visits::Client::Response.new(status: 200, body: wakes_payload.to_json, json: wakes_payload, content_type: "application/json", content_disposition: nil)
    client = FakeClient.new([ ok, ok ])

    assert_enqueued_with(job: Visits::TriggerWakeJob) do
      result = Visits::Poller.new(@visit, client: client).call
      assert_equal :ok, result[:status]
      assert_equal 1, result[:enqueued]
    end

    # Redelivery of wake_1 must NOT enqueue a second TriggerWakeJob.
    assert_no_enqueued_jobs(only: Visits::TriggerWakeJob) do
      result = Visits::Poller.new(@visit, client: client).call
      assert_equal :ok, result[:status]
      assert_equal 0, result[:enqueued]
      assert_equal 1, result[:deduplicated]
    end
    assert_equal 1, @visit.visit_wakes.count
  end

  test "marks visit revoked on 401 from visited house" do
    unauth = Visits::Client::Response.new(status: 401, body: '{"error":"revoked"}', json: { "error" => "revoked" }, content_type: "application/json", content_disposition: nil)
    client = FakeClient.new([ unauth ])

    result = Visits::Poller.new(@visit, client: client).call
    assert_equal :revoked, result[:status]
    assert_equal "revoked", @visit.reload.status
    assert_not_nil @visit.ended_at
  end

  test "stops polling once home wake cap is reached" do
    @visit.update!(max_wakes_per_hour: 1)
    @visit.visit_wakes.create!(remote_wake_id: "w_cap", remote_conversation_id: "c1")
    client = FakeClient.new([])

    result = Visits::Poller.new(@visit, client: client).call
    assert_equal :capped, result[:status]
  end

end
