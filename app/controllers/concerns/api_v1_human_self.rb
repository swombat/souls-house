# Shared by the /api/v1 endpoints where a person acts on themselves (me,
# avatar, accounts). These belong to a person, so resident keys are refused.
module ApiV1HumanSelf

  extend ActiveSupport::Concern

  included do
    before_action :require_human_key!
  end

  private

  def require_human_key!
    return unless current_api_agent

    render json: { error: "This endpoint needs a human API key; resident keys cannot use it" }, status: :forbidden
  end

  # The same AuditLog row the web writes through ApplicationController#audit,
  # with the key's user and account in place of the session's.
  def audit(action, auditable = nil, **data)
    AuditLog.create!(
      user: current_api_user,
      account: current_api_account,
      action: action,
      auditable: auditable,
      data: data.presence,
      ip_address: request.remote_ip,
      user_agent: request.user_agent
    )
  end

  def audit_with_changes(action, record, **extra_data)
    audit(action, record, **AuditLog.data_with_changes(record, **extra_data))
  end

  # The confirmed memberships of enabled accounts, oldest first: the same
  # list as the account switcher and the app API's accounts index.
  def confirmed_memberships_for(user)
    user.confirmed_memberships.joins(:account).merge(Account.enabled).includes(:account).order(:created_at)
  end

  def account_json(membership)
    Api::App::V1::Presenter.account(membership.account, membership)
  end

  def me_json(user)
    profile = user.profile
    avatar_path = profile&.avatar_url
    default_account = user.default_account

    {
      id: user.to_param,
      email_address: user.email_address,
      first_name: user.first_name,
      last_name: user.last_name,
      full_name: user.full_name,
      timezone: user.timezone,
      theme: user.theme,
      theme_hue: user.theme_hue,
      chat_colour: user.chat_colour,
      avatar_url: (avatar_path && "#{request.base_url}#{avatar_path}"),
      default_account_id: user.default_account_key,
      default_account: (default_account && { id: default_account.to_param, name: default_account.name }),
      accounts: confirmed_memberships_for(user).map { |membership| account_json(membership) }
    }
  end

end
