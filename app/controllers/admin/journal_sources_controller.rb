# Which journal a resident's card counts (JqRaEY). The resident chooses; the
# site admin records that choice here. Blank means the dated daily journals.
# Saving clears the old count (Agent#journal_source) and asks for a new one.
class Admin::JournalSourcesController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin
  before_action :set_agent

  def show
    render inertia: "admin/journal-source", props: {
      resident: { id: @agent.to_param, name: @agent.name, account_name: @agent.account.name },
      journal_source: @agent.journal_source,
      stats: @agent.journal_entry_stats.slice("count", "status", "measured_at")
    }
  end

  def update
    before = @agent.journal_source
    if @agent.update(journal_source: params.require(:agent).fetch(:journal_source, nil))
      audit(:admin_update_journal_source, @agent, agent_id: @agent.id, from: before, to: @agent.journal_source)
      AgentJournalStatsJob.request_refresh(@agent) if before != @agent.journal_source
      redirect_to admin_agent_journal_source_path(@agent), notice: "Saved. The card counts again in the background."
    else
      redirect_to admin_agent_journal_source_path(@agent), alert: @agent.errors.full_messages.to_sentence
    end
  end

  private

  def set_agent
    @agent = Agent.includes(:account).find(params[:agent_id])
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
