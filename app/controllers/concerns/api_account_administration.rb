# Shared footing for the human account-administration endpoints under
# /api/v1/account: the web's account pages, reached with a person's key.
#
# Every endpoint is human-only: these are the account holder's settings, not
# a resident's. The account is the one the key names (or `account_id`, via
# requested_account), and the key's person must still be a confirmed member,
# as the web's find_current_user_account! requires. Anything else is 404.
module ApiAccountAdministration

  extend ActiveSupport::Concern

  included do
    before_action :require_human_api_key!
    before_action :set_administered_account
  end

  private

  def require_human_api_key!
    return unless current_api_agent

    render json: { error: "Account administration is only available to a person's API key" }, status: :forbidden
  end

  def set_administered_account
    @account = requested_account
    raise ActiveRecord::RecordNotFound unless @account.accessible_by?(current_api_user)
  end

  # The web's require_account_manager!.
  def require_account_manager!
    return if @account.manageable_by?(current_api_user)

    render_forbidden("You don't have permission to manage this account")
  end

  # The web's require_feature_enabled.
  def require_feature_enabled!(feature)
    return if Setting.instance.public_send(:"allow_#{feature}?")

    render_forbidden("This feature is currently disabled")
  end

  def render_forbidden(message)
    render json: { error: message }, status: :forbidden
  end

  def render_invalid(record)
    render json: { error: record.errors.full_messages.to_sentence.presence || "Invalid", errors: record.errors.to_hash },
           status: :unprocessable_entity
  end

  # The web's audit record for the same action, tagged with the key that did it.
  def audit(action, auditable = nil, **data)
    AuditLog.create!(
      user: current_api_user,
      account: @account,
      action: action,
      auditable: auditable,
      data: data.merge(api_key_id: Current.api_key&.id),
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end

  # The web's audit_with_changes: saved changes, filtered like request params.
  def audit_with_changes(action, record, **extra_data)
    changes = record.saved_changes.except(:updated_at)
    data = ActiveSupport::ParameterFilter
      .new(Rails.application.config.filter_parameters)
      .filter(extra_data.merge(changes))

    audit(action, record, **data.symbolize_keys)
  end

end
