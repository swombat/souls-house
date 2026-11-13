# Commitments a person may see and adjust (Commitment). A resident hosted
# here shows them on its own page (AgentsController#edit, Commitments tab);
# a guest resident has this page, which opens nothing else about the guest
# and shows only commitments made in this house. Whoever may manage a
# commitment (Commitment#manageable_by?) can reschedule or cancel it. There
# is no create: residents make their own (Api::V1::CommitmentsController).
class Agents::CommitmentsController < ApplicationController

  require_feature_enabled :agents
  before_action :set_agent
  before_action :set_commitment, only: %i[update destroy]

  def index
    render inertia: "agents/commitments", props: {
      agent: { id: @agent.to_param, name: @agent.name, guest: guest? },
      commitments: -> { CommitmentPresentation.new(agent: @agent, account: current_account, viewer: Current.user, routes: helpers).as_props },
      back_url: account_agents_path(current_account),
      can_manage_essential: Agents::AllowanceBrake.manageable_by?(current_account, Current.user)
    }
  end

  def update
    if params.key?(:essential)
      return head :forbidden unless Agents::AllowanceBrake.manageable_by?(@commitment.account, Current.user)
      @commitment.update!(essential: ActiveModel::Type::Boolean.new.cast(params[:essential]))
      return redirect_to back_path, notice: "Commitment updated" unless params.key?(:due_at)
    end
    due_at = parse_due_at(params[:due_at])
    result = due_at ? @commitment.reschedule!(due_at: due_at) : nil
    flash_args = case result&.status
    when :rescheduled then { notice: "Commitment rescheduled" }
    when :not_scheduled then { alert: "Only a scheduled commitment can be rescheduled" }
    else { alert: @commitment.errors.full_messages.to_sentence.presence || "Give a valid time in the future" }
    end
    redirect_to back_path, **flash_args
  end

  def destroy
    result = @commitment.cancel!(by: Current.user)
    flash_args = result.status == :cancelled ? { notice: "Commitment cancelled" } : { alert: "This commitment has already been delivered or cancelled" }
    redirect_to back_path, **flash_args
  end

  private

  # Residents hosted here, guests seated here, and former guests that made
  # commitments here (so a departed guest's promises stay visible and
  # manageable). Guests reach only this controller, never their settings.
  def set_agent
    with_commitments_here = Agent.where(id: Commitment.where(account_id: current_account.id).select(:agent_id))
    @agent = current_account.conversation_agents.or(with_commitments_here).find(params[:agent_id])
  end

  def guest?
    @agent.account_id != current_account.id
  end

  def set_commitment
    scope = CommitmentPresentation.visible_scope(agent: @agent, account: current_account, viewer: Current.user)
    @commitment = scope.find(params[:id])
    return if action_name == "update" && params.key?(:essential) && !params.key?(:due_at) &&
      Agents::AllowanceBrake.manageable_by?(@commitment.account, Current.user)
    head :forbidden unless @commitment.manageable_by?(Current.user)
  end

  def back_path
    if guest?
      account_agent_commitments_path(current_account, @agent)
    else
      edit_account_agent_path(current_account, @agent, tab: "commitments")
    end
  end

  # The page sends an instant in UTC (toISOString).
  def parse_due_at(value)
    Time.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

end
