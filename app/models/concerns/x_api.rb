require "net/http"
require "json"

module XApi

  extend ActiveSupport::Concern

  X_AUTHORIZE_URL = "https://x.com/i/oauth2/authorize"
  X_TOKEN_URL = "https://api.x.com/2/oauth2/token"
  X_API_BASE = "https://api.x.com/2"
  SCOPES = %w[tweet.write tweet.read users.read offline.access].freeze

  class Error < StandardError; end

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

  def exchange_code!(code:, redirect_uri:, code_verifier:)
    response = post_token(
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      code_verifier: code_verifier
    )

    save_tokens!(response)
    fetch_username!
  end

  def refresh_tokens!
    return if token_fresh?

    response = post_token(
      grant_type: "refresh_token",
      refresh_token: refresh_token
    )

    save_tokens!(response)
  end

  def token_fresh?
    token_expires_at.present? && token_expires_at > 5.minutes.from_now
  end

  def connected?
    access_token.present? && refresh_token.present?
  end

  def disconnect!
    update!(access_token: nil, refresh_token: nil, token_expires_at: nil, x_username: nil)
  end

  private

  def x_credentials(key)
    Rails.application.credentials.dig(:x, key) ||
      raise(ArgumentError, "X #{key} not configured in credentials")
  end

  def save_tokens!(response)
    raise Error, "Token exchange failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    update!(
      access_token: data["access_token"],
      refresh_token: data["refresh_token"].presence || refresh_token,
      token_expires_at: data["expires_in"].to_i.seconds.from_now
    )
  end

  def fetch_username!
    uri = URI("#{X_API_BASE}/users/me")
    request = Net::HTTP::Get.new(uri)
    request["Authorization"] = "Bearer #{access_token}"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) }
    return unless response.is_a?(Net::HTTPSuccess)

    data = JSON.parse(response.body)
    update!(x_username: data.dig("data", "username"))
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
