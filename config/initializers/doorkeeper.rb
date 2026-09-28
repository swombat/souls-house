# Native-app sign-in (issue #94, PR A). Authorization code + PKCE (S256 only)
# for public first-party clients, short access tokens, rotating refresh tokens
# with Doorkeeper's deferred revocation, and our own reuse detection on top
# (AppSession, Oauth::TokensController).
Doorkeeper.configure do
  orm :active_record

  # The phone opens the system browser on /oauth/authorize. If the web session
  # cookie is there we know the user; otherwise they log in on the normal page
  # and come back.
  resource_owner_authenticator do
    cookie_name = LocalInstance.current.cookie(:session_id)
    session_id = cookies.signed[cookie_name]
    web_session = Session.find_by(id: session_id) if session_id

    if web_session
      web_session.user
    else
      session[:return_to_after_authenticating] = request.fullpath
      redirect_to(login_url)
      nil
    end
  end

  # No web UI for managing OAuth applications; first-party clients are
  # provisioned by `bin/rails app_clients:ensure`.
  admin_authenticator { head :forbidden }

  grant_flows %w[authorization_code]
  force_pkce
  pkce_code_challenge_methods %w[S256]

  # First-party clients only: the user already chose to sign in to our app,
  # and the code can only go to an exactly-registered callback.
  skip_authorization { true }

  access_token_expires_in 15.minutes
  authorization_code_expires_in 5.minutes
  use_refresh_token
  hash_token_secrets
  hash_application_secrets

  default_scopes :chat
  enforce_configured_scopes

  # Copied grant → first token → each refreshed token. Client-supplied at
  # authorize time, display only. app_session_id is deliberately NOT here:
  # anything listed is accepted from authorize params.
  custom_access_token_attributes [ :device_label ]

  force_ssl_in_redirect_uri { |uri| !(Rails.env.local? && uri.host.in?(%w[localhost 127.0.0.1])) }

  # No custom URL schemes, no wildcard or native "urn:" callbacks: only the
  # exact HTTPS callbacks registered on the application.
  forbid_redirect_uri { |uri| uri.scheme.to_s.downcase != "https" && !Rails.env.local? }

  # Not part of the native-app contract; nothing should be able to probe tokens.
  allow_token_introspection false

  base_controller "ActionController::Base"
end

Rails.application.config.to_prepare do
  Doorkeeper::AccessToken.class_eval do
    belongs_to :app_session

    before_validation :attach_app_session, on: :create

    private

    # A refresh carries its predecessor's session forward; a first token from
    # an authorization code starts a new device session.
    def attach_app_session
      return if app_session_id.present?

      predecessor = self.class.by_previous_refresh_token(previous_refresh_token) if previous_refresh_token.present?
      self.app_session_id = predecessor&.app_session_id || AppSession.create!(
        user_id: resource_owner_id,
        oauth_application_id: application_id,
        device_label: device_label.to_s.first(100).presence
      ).id
    end
  end
end
