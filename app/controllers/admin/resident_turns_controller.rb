class Admin::ResidentTurnsController < ApplicationController

  skip_before_action :set_current_account
  before_action :require_site_admin

  def index
    turns = ResidentTurn.pending.includes(:agent, :agent_runtime_interaction).order(:created_at).limit(200)
    render inertia: "admin/resident-turns", props: {
      enabled: ResidentTurn.enabled?, limit: ResidentTurn.capacity,
      counts: ResidentTurn.pending.group(:state).count,
      turns: turns.map { |turn|
        {
          id: turn.id, resident: turn.agent.name, state: turn.state,
          kind: turn.agent_runtime_interaction.trigger_kind,
          diagnostic: turn.completion_context["dispatch_diagnostic"],
          queued_at: turn.created_at.iso8601, admitted_at: turn.admitted_at&.iso8601,
          checked_at: turn.checked_at&.iso8601, cancel_requested: turn.cancel_requested_at?
        }
      }
    }
  end

  def update
    setting = Setting.instance
    if setting.update(resident_turn_limit: params.require(:limit))
      audit_with_changes("update_resident_turn_limit", setting)
      ResidentTurnDispatchJob.perform_later
      redirect_to admin_resident_turns_path
    else
      redirect_to admin_resident_turns_path, inertia: { errors: setting.errors.to_hash }
    end
  end

  def destroy
    turn = ResidentTurn.find(params[:id])
    turn.cancel!
    redirect_to admin_resident_turns_path, notice: "Cancellation requested; capacity stays reserved until exit is confirmed."
  end

  private

  def require_site_admin
    redirect_to root_path unless Current.user&.is_site_admin?
  end

end
