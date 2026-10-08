# Shared by the /api/v1 endpoints where a person acts on themselves (me,
# avatar, accounts). The authority rules come from ApiHumanActor; what lives
# here is how these endpoints apply them, and their presenters.
#
# Identity and discovery never need a selected account: an OAuth token with
# no usable default account still reads /me and lists /accounts. An account
# credential (API key) must still belong to an enabled account its person is a
# current confirmed member of, and an account the request names with
# account_id must be usable too; otherwise 404, as everywhere in /api/v1.
#
# Method names are prefixed (self_*) so they cannot collide with presenters
# in other /api/v1 controllers.
module ApiV1SelfEndpoints

  extend ActiveSupport::Concern

  included do
    before_action :require_human_actor!
    before_action :require_usable_self_account!
  end

  private

  # Also fixes the audit account before anything changes, so a request that
  # changes the default account is filed under the account it started in.
  def require_usable_self_account!
    human_account! if @current_api_key || params[:account_id].present?
    self_audit_account
  end

  # The account an audit row is filed under: the key's account, the account
  # the request names, or the OAuth person's default enabled account. Nil when
  # an OAuth person has no usable account; acting on themselves needs none.
  def self_audit_account
    return @self_audit_account if defined?(@self_audit_account)

    @self_audit_account = begin
      current_api_account
    rescue ApiAuthentication::NoAccount
      nil
    end
  end

  def self_audit_with_changes(action, user)
    audit_human_action(action, user, account: self_audit_account, **AuditLog.data_with_changes(user))
  end

  # The confirmed memberships of enabled accounts, oldest first: the same
  # list as the account switcher and the app API's accounts index.
  def self_usable_memberships(user)
    user.confirmed_memberships.joins(:account).merge(Account.enabled).includes(:account).order(:created_at)
  end

  def self_listed_account_json(membership)
    Api::App::V1::Presenter.account(membership.account, membership)
  end

  # The account used when a request names none: the person's choice if it is
  # still usable, otherwise their earliest usable membership (the same rule
  # ApiAuthentication applies to OAuth tokens). Nil if they have none.
  def self_effective_default_account(user, memberships)
    chosen = memberships.find { |membership| membership.account_id == user.default_account_id }
    (chosen || memberships.first)&.account
  end

  def self_user_json(user)
    profile = user.profile
    avatar_path = profile&.avatar_url
    memberships = self_usable_memberships(user).to_a
    default_account = self_effective_default_account(user, memberships)

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
      accounts: memberships.map { |membership| self_listed_account_json(membership) }
    }
  end

end
