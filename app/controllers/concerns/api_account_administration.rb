# What the account-administration endpoints under /api/v1/account add to the
# shared ApiHumanActor guard: the web's role and feature checks, its error
# shapes, and its audit_with_changes.
#
# Who may act, and where, is ApiHumanActor's: human credentials only, and
# only in an enabled account where the person is a current, confirmed member
# (else 404). Account-level actions act in the selected account
# (`account_id`, else the credential's account or the person's default).
# Actions on one record act in that record's account: with an OAuth token and
# no `account_id` the record may be in any of the person's accounts; naming
# an account, or using an account key, narrows the lookup to that account.
module ApiAccountAdministration

  extend ActiveSupport::Concern

  included do
    before_action :require_human_actor!
  end

  private

  # before_action for account-level actions: the selected account.
  def set_administered_account
    administer!(requested_account)
  end

  # Makes `account` the one this request acts in, if the person may act there.
  def administer!(account)
    @account = human_account!(account)
  end

  # The credential's scope for a lookup by record id: every account an OAuth
  # token's person belongs to (no account_id), else only the selected account
  # (an account key's own account, or the one account_id names). Records are
  # always found through this relation first, never globally, because
  # human_account! checks membership only, not the credential's scope. Each
  # record found is then passed to administer!.
  def administrable_accounts
    return current_api_user.confirmed_accounts if app_token_request? && params[:account_id].blank?

    Account.where(id: human_account!(requested_account).id)
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

  # The web's audit record for the same action, with the acting credential.
  def audit(action, auditable = nil, **data)
    audit_human_action(action, auditable, account: @account, **data)
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
