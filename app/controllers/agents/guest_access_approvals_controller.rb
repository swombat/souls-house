# The home's answer to another house sharing a connection with one of its
# residents (JWblqj): approve or decline the particular request shown
# (generation), or revoke an approval. Account owners only, as for ending a
# guest membership (GuestMembership#removable_by?). Every decision is
# recorded in the grant's own history and the audit log.
class Agents::GuestAccessApprovalsController < ApplicationController

  DECISIONS = %w[approve decline revoke].freeze

  before_action :set_access

  def update
    return deny_account_access!("Only an owner of this account can decide what its residents use elsewhere") unless current_account.owned_by?(Current.user)

    decision = params.require(:decision).to_s
    raise ActionController::BadRequest, "unknown decision" unless decision.in?(DECISIONS)

    case decision
    when "approve" then @access.approve_home!(actor: Current.user, generation: params.require(:generation))
    when "decline" then @access.decline_home!(actor: Current.user, generation: params.require(:generation))
    when "revoke" then @access.revoke_home!(actor: Current.user)
    end
    audit(:"#{decision}_guest_service_access", @connection,
          resident_id: @agent.to_param, provider: @connection.provider,
          sharing_account_id: @connection.account_id, generation: @access.home_approval_generation)
    notice = case decision
    when "approve" then "#{@agent.name} can now use #{@connection.display_label} from #{@connection.account.name}"
    when "decline" then "Declined. #{@connection.account.name} can ask again."
    else "Revoked. #{@connection.account.name} would need a new approval to share this again."
    end
    redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"), notice: notice
  rescue AgentServiceAccess::HomeApprovalRefused => error
    redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"), alert: error.message
  end

  private

  # Only a grant from another house reaches here; a hosted row is managed on
  # the Integrations page and is reported as missing.
  def set_access
    @agent = current_account.agents.find(params[:agent_id])
    @connection = ServiceConnection.find_by_public_id!(params[:id])
    @access = @agent.agent_service_accesses.find_by!(service_connection: @connection)
    raise ActiveRecord::RecordNotFound unless @access.foreign?
  end

end
