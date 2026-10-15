# One account's X handle, and the X app it connects through.
#
# The house X app (x.client_id / x.client_secret in Rails credentials) is for
# accounts with a site admin among their confirmed members, and for accounts a
# site admin has granted it to (accounts.x_posting_house_app). Every other
# account enters its own X app's client id and secret, and pays X for its own
# posts; it never falls back to the house app. An account that has entered
# its own app uses it even when it could use the house app.
#
# Tokens belong to the app that issued them, so changing or removing the own
# app disconnects the handle and switches posting off, and so does losing the
# house app while connected through it.
class XIntegration < ApplicationRecord

  include XApi

  belongs_to :account
  has_many :tweet_logs, dependent: :destroy

  encrypts :client_secret

  validates :account_id, uniqueness: true
  validates :client_id, length: { maximum: 200 }
  validates :client_secret, length: { maximum: 500 }

  scope :enabled, -> { where(enabled: true) }

  def self.house_app_configured?
    Rails.application.credentials.dig(:x, :client_id).present? &&
      Rails.application.credentials.dig(:x, :client_secret).present?
  end

  def own_app? = client_id.present? && client_secret.present?

  def house_app_allowed? = account.x_posting_house_app? || account.includes_site_admin?

  # "site_admin", "granted", or nil: why this account may use the house app.
  def house_app_reason
    if account.includes_site_admin? then "site_admin"
    elsif account.x_posting_house_app? then "granted"
    end
  end

  # After a site admin withdraws the house app grant: an integration
  # connected through the house app that can no longer use it disconnects,
  # under the same row lock as an app change, so it waits for a send in
  # progress and bumps app_generation against an OAuth exchange in flight.
  # An account with its own app, or still with a site admin, is untouched.
  def self.house_app_access_changed!(account)
    account.x_integration&.disconnect_unless_house_app_allowed!
  end

  def disconnect_unless_house_app_allowed!
    with_lock do
      account.reload
      next if own_app? || house_app_allowed?

      update!(**disconnected_attributes)
    end
  end

  # "own", "house", or nil when this account has no X app to connect through.
  def app_source
    return "own" if own_app?
    return "house" if house_app_allowed? && self.class.house_app_configured?

    nil
  end

  def app_available? = app_source.present?

  # Changing or removing the app takes the integration's row lock, so it
  # waits for a send in progress (XPoster holds the row in share mode while
  # sending) and for a token refresh. Bumping app_generation makes any OAuth
  # exchange or refresh begun under the old app discard its tokens.
  def set_own_app!(client_id:, client_secret:)
    client_id = client_id.to_s.strip
    client_secret = client_secret.to_s.strip
    raise ArgumentError, "Both the client id and the client secret are needed" if client_id.blank? || client_secret.blank?

    with_lock do
      next if client_id == self.client_id && client_secret == self.client_secret

      update!(client_id:, client_secret:, **disconnected_attributes)
    end
  end

  def remove_own_app!
    with_lock { update!(client_id: nil, client_secret: nil, **disconnected_attributes) }
  end

  private

  def disconnected_attributes
    { access_token: nil, refresh_token: nil, token_expires_at: nil, x_username: nil, enabled: false, app_generation: app_generation + 1 }
  end

  def x_credentials(key)
    case app_source
    when "own" then key == :client_id ? client_id : client_secret
    when "house" then Rails.application.credentials.dig(:x, key)
    end.presence || raise(XApi::Error, "No X app is set up for this account")
  end

end
