require "test_helper"

class SiteDashboardTest < ActiveSupport::TestCase

  setup do
    @public_agent = agents(:research_assistant)
    @founding_agent = agents(:other_account_agent)
    @founding_agent.account.update!(founding: true)
  end

  def interaction(agent, kind: "conversation", status: "ok", at: 1.hour.ago, **attributes)
    AgentRuntimeInteraction.create!(
      agent:, trigger_kind: kind, started_at: at, finished_at: at + 5.seconds, runtime_status: status,
      requested_by: "test", session_id: SecureRandom.hex(4), **attributes
    )
  end

  def priced(**attributes)
    { model: "anthropic/claude-opus-5.5", provider: "anthropic", telemetry_schema_version: 1,
      usage_scope: "trigger", uncached_input_tokens: 1_000_000, cache_creation_input_tokens: 0,
      cache_read_input_tokens: 0, output_tokens: 0 }.merge(attributes)
  end

  test "founding accounts stay out of growth counts" do
    data = SiteDashboard.new.call
    assert_not_includes Agent.where(account_id: Account.where(founding: false)).pluck(:id), @founding_agent.id
    assert_equal Agent.active.where.not(account_id: @founding_agent.account_id).count, data[:headline][:residents][:value]
    assert_equal Account.where(founding: false).count, data[:headline][:accounts][:value]
    assert_equal 1, data[:headline][:founding][:accounts]
    assert_equal [ @founding_agent.account.to_param ], data[:founding].map { |row| row[:id] }
  end

  test "failure rate counts errors and timeouts among finished turns" do
    interaction(@public_agent)
    interaction(@public_agent, status: "error")
    interaction(@founding_agent, status: "timeout", kind: "wake")
    interaction(@founding_agent, at: 10.days.ago, status: "error")

    reliability = SiteDashboard.new.call[:reliability]
    assert_equal 3, reliability[:turns_finished]
    assert_equal 2, reliability[:turns_failed]
    assert_in_delta 0.6667, reliability[:failure_rate], 0.001
    assert_equal({ "conversation" => 1, "wake" => 1 }, reliability[:failures_by_kind])
  end

  test "activity splits channels and keeps the growth-only series separate" do
    interaction(@public_agent, kind: "wake")
    interaction(@founding_agent, kind: "wake")
    interaction(@founding_agent, kind: "memory_aggregation_daily")

    activity = SiteDashboard.new.call[:activity]
    assert_equal 2, activity[:everyone]["wake"].last
    assert_equal 1, activity[:growth]["wake"].last
    assert_equal 1, activity[:everyone]["memory"].last
    assert_equal 0, activity[:growth]["memory"].last
  end

  test "model spend is split into bands, and subscription turns are an estimate not spend" do
    interaction(@public_agent, **priced)
    interaction(@founding_agent, **priced)
    interaction(@founding_agent, **priced(provider_auth_mode: "oauth_account"))
    interaction(@public_agent, model: "unknown/model")

    costs = SiteDashboard.new.call[:costs]
    assert_in_delta 4.0, costs[:public][:api_usd], 0.001
    assert_in_delta 4.0, costs[:public][:per_active_resident_usd], 0.001
    assert_equal 1, costs[:public][:unpriced_turns]
    assert_in_delta 4.0, costs[:founding][:api_usd], 0.001
    assert_in_delta 4.0, costs[:founding][:subscription_estimate_usd], 0.001
    assert_in_delta 4.0, costs[:public][:daily_usd].last, 0.001
  end

  test "backup totals carry each resident's last good snapshot forward" do
    AgentBackupSnapshot.create!(agent: @public_agent, restic_snapshot_id: "a", size_bytes: 100, ok: true, taken_at: 40.days.ago)
    AgentBackupSnapshot.create!(agent: @founding_agent, restic_snapshot_id: "b", size_bytes: 50, ok: true, taken_at: 3.days.ago)
    AgentBackupSnapshot.create!(agent: @founding_agent, restic_snapshot_id: "c", size_bytes: 999, ok: false, taken_at: 1.hour.ago)

    data = SiteDashboard.new.call
    backups = data[:backups]
    assert_equal 150, backups[:logical_bytes]
    assert_equal 100, backups[:daily_logical_bytes].first
    assert_equal 150, backups[:daily_logical_bytes].last
    assert_equal [ @public_agent.name, @founding_agent.name ], backups[:largest].map { |row| row[:name] }
    assert data[:reliability][:oldest_open_failure_at].present?
  end

  test "failures from kinds that share a channel are summed, not overwritten" do
    2.times { interaction(@public_agent, kind: "memory_aggregation_daily", status: "error") }
    3.times { interaction(@public_agent, kind: "memory_aggregation_weekly", status: "error") }
    interaction(@public_agent, kind: "orientation", status: "error")
    interaction(@public_agent, kind: "safeguard_reclaim_offer", status: "timeout")

    assert_equal({ "memory" => 5, "other" => 2 }, SiteDashboard.new.call[:reliability][:failures_by_kind])
  end

  test "a finished turn with a recorded error and no runtime status counts as failed, a busy conflict does not" do
    interaction(@public_agent, status: nil, error_class: "Errno::ECONNREFUSED", error_message: "refused")
    interaction(@public_agent, status: nil, execution_state: "timed_out")
    interaction(@public_agent, status: "already_running", execution_state: "busy")
    interaction(@public_agent)

    reliability = SiteDashboard.new.call[:reliability]
    assert_equal 4, reliability[:turns_finished]
    assert_equal 2, reliability[:turns_failed]
    assert_equal 0.5, reliability[:failure_rate_daily].last
  end

  test "an unresolved Hetzner purchase is reported, not counted as a VM" do
    placement = AgentPlacement.create!(agent: @public_agent, backend: "hetzner_cloud", location: "nbg1")
    CloudProcurementOperation.create!(agent_placement: placement, requested_by: users(:site_admin_user),
      public_id: SecureRandom.hex(4), approval_reference: "test", location: "nbg1", server_type: "cx23",
      image_id: 1, ssh_key_ids: [ 1 ], provider_name: "resident-#{SecureRandom.hex(3)}", state: "unknown")

    placement_data = SiteDashboard.new.call[:placement]
    assert_empty placement_data[:vms]
    assert_equal({ "unknown" => 1 }, placement_data[:unresolved_procurements])
  end

end
