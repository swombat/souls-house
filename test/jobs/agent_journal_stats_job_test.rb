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

  test "a count measured while the chosen journal changed is not put on the new journal's card" do
    @agent.update_columns(journal_stats_requested_at: Time.current)
    assert_no_enqueued_jobs(only: AgentJournalStatsJob) { AgentJournalStatsJob.request_refresh(@agent) }
    assert_enqueued_jobs(1, only: AgentJournalStatsJob) { AgentJournalStatsJob.request_refresh(@agent, force: true) }

    service = Struct.new(:call).new({ status: "measured", count: 0 })
    measuring = lambda do |*|
      Agent.find(@agent.id).update!(journal_source: "memory/growth-journal.md")
      service
    end
    Agents::JournalEntryStats.stub(:new, measuring) do
      AgentJournalStatsJob.perform_now(@agent.id)
    end
    @agent.reload
    assert_equal "memory/growth-journal.md", @agent.journal_source
    assert_equal({}, @agent.journal_entry_stats)
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
