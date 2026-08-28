require "net/http"
require "json"
require "base64"
require "digest"

module Services
  class GoogleWorkspaceAdapter

    AUTHORIZE_URL = "https://accounts.google.com/o/oauth2/v2/auth"
    TOKEN_URL = "https://oauth2.googleapis.com/token"
    IDENTITY_URL = "https://openidconnect.googleapis.com/v1/userinfo"
    REVOKE_URL = "https://oauth2.googleapis.com/revoke"

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def authorization_url(attempt, state:, redirect_uri:)
      challenge = Base64.urlsafe_encode64(
        Digest::SHA256.digest(attempt.pkce_verifier),
        padding: false
      )
      "#{AUTHORIZE_URL}?#{{
        response_type: "code",
        client_id: client_id,
        redirect_uri: redirect_uri,
        access_type: "offline",
        prompt: "consent",
        scope: attempt.requested_scopes.join(" "),
        state: state,
        code_challenge: challenge,
        code_challenge_method: "S256"
      }.to_query}"
    end

    def exchange_code(code:, attempt:, redirect_uri:)
      data = token_request(
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri,
        code_verifier: attempt.pkce_verifier
      )
      identity = fetch_identity(data.fetch("access_token"))

      {
        external_subject_id: identity.fetch("sub"),
        external_identity: identity["email"].presence || identity["name"],
        credential_kind: "oauth2",
        credential_payload: credential_payload(data),
        credential_metadata: {
          "granted_scopes" => data["scope"].to_s.split.presence || attempt.requested_scopes,
          "credential_strategy" => definition.credential_strategy
        }
      }
    end

    def current_access_token(connection)
      connection.with_lock do
        connection.reload
        payload = connection.credential_payload_hash
        return payload.fetch("access_token") if token_fresh?(payload)

        refresh_token = payload["refresh_token"].presence ||
          raise(Error, "Google Workspace refresh token is unavailable; reconnect Google Workspace")
        data = token_request(grant_type: "refresh_token", refresh_token: refresh_token)
        refreshed_payload = credential_payload(data, previous_refresh_token: refresh_token)
        connection.replace_credential_payload_without_reconciliation!(refreshed_payload)
        refreshed_payload.fetch("access_token")
      end
    end

    def revoke(connection)
      payload = connection.credential_payload_hash
      token = payload["refresh_token"].presence || payload["access_token"]
      return if token.blank?

      Net::HTTP.post_form(URI(REVOKE_URL), token: token)
    rescue StandardError => e
      Rails.logger.warn("Google Workspace token revocation failed for service connection #{connection.id}: #{e.class}")
    end

    private

    def token_request(params)
      response = Net::HTTP.post_form(URI(TOKEN_URL), params.merge(
        client_id: client_id,
        client_secret: client_secret
      ))
      parse_success(response, "Google OAuth token exchange")
    end

    def fetch_identity(access_token)
      uri = URI(IDENTITY_URL)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      parse_success(
        Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(request) },
        "Google identity lookup"
      )
    end

    def credential_payload(data, previous_refresh_token: nil)
      {
        "access_token" => data.fetch("access_token"),
        "refresh_token" => data["refresh_token"].presence || previous_refresh_token,
        "expires_at" => data["expires_in"].to_i.seconds.from_now.utc.iso8601
      }.compact
    end

    def token_fresh?(payload)
      expires_at = Time.iso8601(payload["expires_at"].to_s)
      payload["access_token"].present? && expires_at > 1.minute.from_now
    rescue ArgumentError
      false
    end

    def parse_success(response, label)
      raise Error, "#{label} failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "#{label} returned invalid JSON"
    end

    def client_id
      Rails.application.credentials.dig(:google_workspace, :client_id) ||
        ENV["GOOGLE_WORKSPACE_CLIENT_ID"] ||
        raise(ArgumentError, "Google Workspace client_id is not configured")
    end

    def client_secret
      Rails.application.credentials.dig(:google_workspace, :client_secret) ||
        ENV["GOOGLE_WORKSPACE_CLIENT_SECRET"] ||
        raise(ArgumentError, "Google Workspace client_secret is not configured")
    end

  end
end
