require "test_helper"

class Agents::CardDiskTest < ActiveSupport::TestCase

  setup { @agent = agents(:research_assistant) }

  def local(usage)
    @agent.storage_usage = usage
    Agents::CardDisk.call(@agent, remote: false)
  end

  test "a resident here shows the daily walk" do
    assert_equal({}, local({}))
    assert_equal({}, local({ "status" => "not_applicable" }))
    disk = local({ "status" => "measured", "bytes" => 120_500_000_000, "volumes" => { "work" => 1 },
                   "measured_at" => "2026-11-23T04:20:13Z", "checked_at" => "2026-11-23T04:20:13Z", "attempt_seconds" => 109.4 })
    assert_equal({ "status" => "measured", "bytes" => 120_500_000_000, "measured_at" => "2026-11-23T04:20:13Z",
                   "attempted_at" => "2026-11-23T04:20:13Z" }, disk)
    assert_equal "measured", local({ "status" => "partial", "bytes" => 3 })["status"]
  end

  test "a failed daily walk keeps its last size, and says whether it ran out of time" do
    timeout = local({ "status" => "unavailable", "failure" => "timeout", "bytes" => 9, "checked_at" => "2026-11-23T04:25:00Z" })
    assert_equal [ "too_slow", 9, "2026-11-23T04:25:00Z" ], timeout.values_at("status", "bytes", "attempted_at")
    failed = local({ "status" => "unavailable", "failure" => "docker_unavailable" })
    assert_equal({ "status" => "unavailable", "reason" => "failed" }, failed)
    # The walker's own timeout kills du: du_failed after its whole budget.
    budget = Agents::StorageUsage::DU_SECONDS
    assert_equal "too_slow", local({ "status" => "unavailable", "failure" => "du_failed", "attempt_seconds" => budget + 0.4 })["status"]
    assert_equal "unavailable", local({ "status" => "unavailable", "failure" => "du_failed", "attempt_seconds" => 2.0 })["status"]
  end

  test "a VM resident shows its runner's walk, and only the card's fields" do
    @agent.home_storage = { "status" => "unavailable", "reason" => "runner_too_old", "attempted_at" => "t", "extra" => 1 }
    @agent.storage_usage = { "status" => "unavailable", "failure" => "ownership" }
    assert_equal({ "status" => "unavailable", "reason" => "runner_too_old", "attempted_at" => "t" },
                 Agents::CardDisk.call(@agent, remote: true))
    @agent.home_storage = {}
    assert_equal({}, Agents::CardDisk.call(@agent, remote: true))
  end

end
