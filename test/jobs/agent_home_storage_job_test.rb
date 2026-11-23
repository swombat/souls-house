require "test_helper"

class AgentHomeStorageJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", home_storage: {}, home_storage_requested_at: nil)
  end

  test "each resident is walked at most once an hour, on the background queue" do
    assert_enqueued_jobs 1, only: AgentHomeStorageJob, queue: "background" do
      3.times { AgentHomeStorageJob.request_refresh(@agent) }
    end
    service = Struct.new(:call).new({ "status" => "measured", "bytes" => 12 })
    Agents::HomeStorage.stub(:new, ->(*) { service }) do
      AgentHomeStorageJob.perform_now(@agent.id)
    end
    assert_equal 12, @agent.reload.home_storage["bytes"]
    travel 30.minutes do
      assert_no_enqueued_jobs(only: AgentHomeStorageJob) { AgentHomeStorageJob.request_refresh(@agent) }
    end
    travel 61.minutes do
      assert_enqueued_jobs(1, only: AgentHomeStorageJob) { AgentHomeStorageJob.request_refresh(@agent) }
    end
  end

  test "the count's refresh doesn't touch the size, nor the size's the count" do
    @agent.update_columns(journal_entry_stats: { "count" => 4, "status" => "measured" },
                          home_storage: { "status" => "measured", "bytes" => 9 })
    Agents::JournalEntryStats.stub(:new, ->(*) { Struct.new(:call).new({ status: "measured", count: 5 }) }) do
      AgentJournalStatsJob.perform_now(@agent.id)
    end
    assert_equal 9, @agent.reload.home_storage["bytes"]
    Agents::HomeStorage.stub(:new, ->(*) { Struct.new(:call).new({ "status" => "measured", "bytes" => 10 }) }) do
      AgentHomeStorageJob.perform_now(@agent.id)
    end
    assert_equal [ 5, 10 ], [ @agent.reload.journal_entry_stats["count"], @agent.home_storage["bytes"] ]
  end

  test "deleted and deprecated residents are ignored" do
    @agent.update_columns(runtime: "deprecated")
    assert_no_enqueued_jobs(only: AgentHomeStorageJob) { AgentHomeStorageJob.request_refresh(@agent) }
    Agents::HomeStorage.stub(:new, ->(*) { flunk "must not walk" }) do
      AgentHomeStorageJob.perform_now(@agent.id)
      AgentHomeStorageJob.perform_now(-1)
    end
  end

end
