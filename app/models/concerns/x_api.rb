require "net/http"
require "json"

module XApi

  extend ActiveSupport::Concern

  X_AUTHORIZE_URL = "https://x.com/i/oauth2/authorize"
  X_TOKEN_URL = "https://api.x.com/2/oauth2/token"
  X_API_BASE = "https://api.x.com/2"
  # media.write lets a post carry an image or a video. A grant made before
  # the house asked for it does not have it; granted_scopes records what X
  # actually granted, and media posting asks the owner to reconnect.
  SCOPES = %w[tweet.write tweet.read users.read offline.access media.write].freeze
  MEDIA_SCOPE = "media.write"
  # X's create-post schema: "At most 280 characters unless the account has
  # X Premium." users/me reports the tier in subscription_type (Basic,
  # Premium, PremiumPlus, None). Basic is not documented as allowing long
  # posts, so only these two are trusted.
  LONG_POST_TIERS = %w[Premium PremiumPlus].freeze

  class Error < StandardError; end
  # The account's X app changed (or was removed, or the handle was
  # disconnected) while this exchange or refresh was in flight. Tokens are
  # bound to the app that issued them, so the result is thrown away.
  class StaleApp < Error; end

  included do
    encrypts :access_token
    encrypts :refresh_token
  end

  def authorization_url(state:, redirect_uri:, code_challenge:)
    params = {
      response_type: "code",
      client_id: x_credentials(:client_id),
      redirect_uri: redirect_uri,
      scope: SCOPES.join(" "),
      state: state,
      code_challenge: code_challenge,
      code_challenge_method: "S256"
    }
    query = params.map { |k, v| "#{k}=#{ERB::Util.url_encode(v)}" }.join("&")
    "#{X_AUTHORIZE_URL}?#{query}"
  end

  # app_generation is the generation the authorisation was started under
  # (kept in the session from the Connect click to the callback). The code is
  # exchanged with that app's credentials, and the tokens are saved only if
  # the app is still the same generation when the answer arrives.
  def exchange_code!(code:, redirect_uri:, code_verifier:, app_generation:)
    unless app_generation.is_a?(Integer) && self.app_generation == app_generation && app_available?
      raise StaleApp, "The X app changed after connecting started; connect again"
    end

    response = post_token(
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: code_verifier
    )

    # A new grant can be for a different X user or carry different scopes,
    # so it is a new generation: a post reserved under the old grant is
    # never sent through this one.
    save_tokens!(response, app_generation:, new_grant: true)
    fetch_username!(app_generation: app_generation + 1)
  end

  def refresh_tokens!
    return if token_fresh?

    response = post_token(
      grant_type: "refresh_token",
      refresh_token: refresh_token
    )

    save_tokens!(response, app_generation: self.app_generation)
  end

  def token_fresh?
    token_expires_at.present? && token_expires_at > 5.minutes.from_now
  end

  def connected?
    access_token.present? && refresh_token.present?
  end

  # What X granted, as recorded from its last token response. Never what the
  # house requested: X can grant less, and a refresh never adds a scope.
  def granted_scope?(scope) = granted_scopes.to_s.split.include?(scope)

  def media_scope_granted? = granted_scope?(MEDIA_SCOPE)

  # The connected user's X subscription tier, read from X with this token.
  # Raises XApi::Error when X cannot be asked or does not say.
  def self.subscription_type(access_token)
    uri = URI("#{X_API_BASE}/users/me?user.fields=subscription_type")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    response = begin
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) { |http| http.request(request) }
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError, IOError, EOFError => e
      raise Error, "X could not be asked for the account's subscription (#{e.class.name.demodulize})"
    end
    raise Error, "X answered #{response.code} when asked for the account's subscription" unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body) rescue nil
    tier = data.is_a?(Hash) && data["data"].is_a?(Hash) ? data["data"]["subscription_type"] : nil
    raise Error, "X did not report the account's subscription" unless tier.is_a?(String) && tier.present?

    tier
  end

  def disconnect!
    with_lock { update!(access_token: nil, refresh_token: nil, token_expires_at: nil, x_username: nil, granted_scopes: nil, app_generation: self.app_generation + 1) }
  end

  private

  def save_tokens!(response, app_generation:, new_grant: false)
    raise Error, "Token exchange failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    with_lock do
      raise StaleApp, "The X app changed while its tokens were being fetched; connect again" unless current_app?(app_generation)

      scope = data["scope"].is_a?(String) ? data["scope"].split.join(" ").presence : nil
      attributes = {
        access_token: data["access_token"],
        refresh_token: data["refresh_token"].presence || refresh_token,
        token_expires_at: data["expires_in"].to_i.seconds.from_now,
        # A new grant without a scope answer has unknown scopes; a refresh
        # without one keeps what was recorded (a refresh never adds scopes).
        granted_scopes: new_grant ? scope : (scope || granted_scopes)
      }
      attributes[:app_generation] = self.app_generation + 1 if new_grant
      update!(**attributes)
    end
  end

  def current_app?(app_generation) = self.app_generation == app_generation && app_available?

  def fetch_username!(app_generation:)
    uri = URI("#{X_API_BASE}/users/me")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    return unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    with_lock { update!(x_username: data.dig("data", "username")) if current_app?(app_generation) && connected? }
  end

  def post_token(**params)
    uri = URI(X_TOKEN_URL)
    request = Net::HTTP::Post.new(uri)
    request.set_form_data(params)
    request["Authorization"] = "Basic #{Base64.strict_encode64("#{x_credentials(:client_id)}:#{x_credentials(:client_secret)}")}"
    request["Content-Type"] = "application/x-www-form-urlencoded"

    Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
  end

end
