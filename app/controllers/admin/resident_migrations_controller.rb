# Moving ONE named house resident to its own server (#426, slice 3B).
#
# show is the dry run: every gate with its current answer, and, when asked
# (measure=1), each role home's size against the runner's seed limits. It
# changes nothing. create is the real run, through the same
# Agents::VmMigration#stage! and #activate! (via #move!) and their refusals unchanged: no
# switch here and no gate relaxed, so while placement is off it refuses.
class Admin::ResidentMigrationsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin
  before_action :set_agent

  def show
    migration = Agents::VmMigration.new(@agent)
    measure = params[:measure] == "1"
    report = Agents::VmMigration::Plan.new(migration).call(measure:, requested_by: Current.user)
    render inertia: "admin/resident-migration", props: {
      resident: { id: @agent.id, name: @agent.name, account_name: @agent.account.name },
      report: report.to_h, measured: measure
    }
  end

  def create
    placement = Agents::VmMigration.new(@agent).move!(requested_by: Current.user)
    redirect_to admin_agent_migration_path(@agent),
      notice: "#{@agent.name} is staged and admitted for its own server (placement generation #{placement.reload.generation})."
  rescue Agents::VmMigration::Refused => error
    redirect_to admin_agent_migration_path(@agent), alert: "Not moved: #{error.message}"
  end

  private

  def set_agent
    @agent = Agent.find(params[:agent_id])
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
