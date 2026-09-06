require "test_helper"

class AgentJournalStatsJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external")
  end

  test "refresh requests are throttled including after the job broadcasts" do
    assert_enqueued_jobs 1, only: AgentJournalStatsJob do
      2.times { AgentJournalStatsJob.request_refresh(@agent) }
    end
    service = Struct.new(:call).new({ status: "measured", count: 12 })
    Agents::JournalEntryStats.stub(:new, ->(*) { service }) do
      AgentJournalStatsJob.perform_now(@agent.id)
    end
    assert_equal 12, @agent.reload.journal_entry_stats["count"]
    assert_equal "external", @agent.runtime
    assert_no_enqueued_jobs only: AgentJournalStatsJob do
      AgentJournalStatsJob.request_refresh(@agent)
    end
    travel 3.minutes do
      assert_enqueued_jobs 1, only: AgentJournalStatsJob do
        AgentJournalStatsJob.request_refresh(@agent)
      end
    end
  end

  test "deleted and deprecated residents are ignored" do
    @agent.update_columns(runtime: "deprecated")
    assert_no_enqueued_jobs only: AgentJournalStatsJob do
      AgentJournalStatsJob.request_refresh(@agent)
    end
    Agents::JournalEntryStats.stub(:new, ->(*) { flunk "must not inspect" }) do
      AgentJournalStatsJob.perform_now(@agent.id)
      AgentJournalStatsJob.perform_now(-1)
    end
  end

end
