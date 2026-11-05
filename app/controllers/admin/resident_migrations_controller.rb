# Moving ONE named house resident to its own server (#426, slice 3B).
#
# show is the dry run's gates: every gate with its current answer. measure
# (POST) adds each role home's size against the runner's seed limits and the
# whole archive against Export's. Neither changes the resident. create is the real run, through the same
# Agents::VmMigration#stage! and #activate! (via #move!) and their refusals unchanged: no
# switch here and no gate relaxed, so while placement is off it refuses.
class Admin::ResidentMigrationsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin
  before_action :set_agent

  # The whole measurement must answer inside the proxy's response timeout
  # (config/deploy.yml, 120 s), with room for the audit, rendering and a
  # timed-out read's carrier cleanup (Transport#remove_carrier!, up to 15 s).
  MEASURE_DEADLINE_SECONDS = 90

  # The gates only: reads no volume, so it is safe to reload or prefetch.
  def show
    render_report(measure: false)
  end

  # Reads the resident's volumes (read-only) to measure its home. A POST,
  # because it is an expensive capture that is audited.
  def measure
    render_report(measure: true)
  end

  # The real run takes the carry snapshot (#426 3C), which can run for up to
  # an hour (CarrySnapshot::SECONDS): far past the proxy's 120 s, so
  # a web request would lose its own result. It is refused here, before
  # anything is read or staged, and the page names the rake door, which
  # runs it where nothing times it out.
  def create
    redirect_to admin_agent_migration_path(@agent), alert: "Not moved: #{self.class.apply_command(@agent)}"
  end

  def self.apply_command(agent)
    "a move takes a carry snapshot that can outlast a web request, so it runs from the console: " \
      "bin/rails \"vm:migrate[#{agent.id}]\" MODE=apply REQUESTED_BY=<your email>"
  end

  private

  def render_report(measure:)
    report = Agents::VmMigration::Plan.new(Agents::VmMigration.new(@agent),
      deadline_seconds: (MEASURE_DEADLINE_SECONDS if measure)).call(measure:, requested_by: Current.user)
    render inertia: "admin/resident-migration", props: {
      resident: { id: @agent.id, name: @agent.name, account_name: @agent.account.name },
      report: report.to_h, measured: measure, apply_command: self.class.apply_command(@agent)
    }
  end

  def set_agent
    @agent = Agent.find(params[:agent_id])
  end

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
