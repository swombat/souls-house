# Shared footing for endpoints a person's agent uses on their behalf: the actor
# must be a person (never a resident), may act only in enabled accounts where
# they are currently a confirmed member, and every write is audited with the
# credential that acted (API key or app session). Authority is always checked
# against the account of the thing being acted on, never a default.
module ApiHumanActor

  extend ActiveSupport::Concern

  private

  # before_action: refuses resident keys.
  def require_human_actor!
    return unless current_api_agent

    render json: { error: "This endpoint is for a person's credential, not a resident key" }, status: :forbidden
  end

  # The account, if the acting person currently belongs to it and it is
  # enabled; otherwise 404 (a departed member's key or a disabled account must
  # not confirm the account exists). Defaults to the request's account.
  def human_account!(account = current_api_account)
    raise ActiveRecord::RecordNotFound unless account && current_api_user.confirmed_accounts.exists?(account.id)

    account
  end

  # The acting person's membership of an account they may act in.
  def human_membership!(account = current_api_account)
    current_api_user.confirmed_memberships.find_by!(account_id: human_account!(account).id)
  end

  # Credential provenance for audit rows: which key, or which app session.
  def api_credential_audit_data
    if @current_api_key
      { api_key_id: @current_api_key.id }
    elsif @current_app_session
      { app_session_id: @current_app_session.id }
    else
      {}
    end
  end

  def audit_human_action(action, auditable, account:, **data)
    AuditLog.create!(
      user: current_api_user,
      account: account,
      action: action,
      auditable: auditable,
      data: data.merge(api_credential_audit_data),
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end

end
