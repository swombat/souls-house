require "test_helper"

class Admin::JournalSourcesControllerTest < ActionDispatch::IntegrationTest

  include ActiveJob::TestHelper

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", journal_entry_stats: { "count" => 0, "status" => "measured" })
  end

  test "the site admin records the resident's chosen journal, audited, and the old count goes" do
    sign_in users(:site_admin_user)
    get admin_agent_journal_source_path(@agent)
    assert_response :success

    # Viewing the directory just took the refresh lease; the save must not be swallowed by it.
    @agent.update_columns(journal_stats_requested_at: Time.current)
    assert_enqueued_with(job: AgentJournalStatsJob, args: [ @agent.id ]) do
      patch admin_agent_journal_source_path(@agent), params: { agent: { journal_source: " memory/growth-journal.md " } }
    end
    assert_redirected_to admin_agent_journal_source_path(@agent)
    @agent.reload
    assert_equal "memory/growth-journal.md", @agent.journal_source
    assert_equal({}, @agent.journal_entry_stats)
    log = AuditLog.find_by!(action: "admin_update_journal_source", auditable: @agent)
    assert_equal [ nil, "memory/growth-journal.md" ], log.data.values_at("from", "to")

    patch admin_agent_journal_source_path(@agent), params: { agent: { journal_source: "" } }
    assert_nil @agent.reload.journal_source
  end

  test "a path outside memory/ is refused and nothing changes" do
    sign_in users(:site_admin_user)
    patch admin_agent_journal_source_path(@agent), params: { agent: { journal_source: "memory/../.ssh/id.md" } }
    assert_redirected_to admin_agent_journal_source_path(@agent)
    assert_match(/under memory/, flash[:alert])
    assert_nil @agent.reload.journal_source
    assert_equal 0, @agent.journal_entry_stats["count"]
  end

  test "only a site admin can see or change it" do
    sign_in users(:existing_user)
    patch admin_agent_journal_source_path(@agent), params: { agent: { journal_source: "memory/growth-journal.md" } }
    assert_redirected_to root_path
    assert_nil @agent.reload.journal_source
  end

end
