# Shared footing for /api/v1 endpoints that a person's key drives on their
# behalf (conversation lifecycle, message edits, reply attention). Each mirrors
# a web controller, so it needs what the web has: a person, their confirmed
# membership of the account, and the same audit record.
module ApiHumanActions

  extend ActiveSupport::Concern

  HUMAN_KEY_REQUIRED = "This action is for a person's API key; resident keys cannot use it".freeze

  private

  def require_human_key
    render json: { error: HUMAN_KEY_REQUIRED }, status: :forbidden if current_api_agent
  end

  # The web acts through current membership; a key whose person has since left
  # the account reaches nothing (404, as for any other unreachable account).
  def member_account
    @member_account ||= current_api_user.confirmed_accounts.find(current_api_account.id)
  end

  # The web's audit record for the same action, tagged with the key.
  def audit(action, auditable, **data)
    AuditLog.create!(
      user: current_api_user,
      account: member_account,
      action: action,
      auditable: auditable,
      data: data.merge(api_key_id: Current.api_key&.id),
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end

end
