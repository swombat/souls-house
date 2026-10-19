require "net/http"
require "json"
require "base64"
require "digest"

module Services
  # Xero accounting, through the refresh broker.
  #
  # Xero refresh tokens are single use: every refresh returns a new one and
  # invalidates the old. Any second holder of a refresh token (a resident, a
  # restored database copy) can silently log the connection out by refreshing
  # first. So the house is the only holder: the refresh happens here under the
  # connection's row lock, the new refresh token is stored before the lock is
  # released, and residents only ever receive 30-minute access tokens.
  #
  # One connection covers every organisation the person ticked on Xero's
  # consent screen. The tenant list is recorded in credential_metadata for
  # display; residents read the live list from GET https://api.xero.com/connections.
  class XeroAdapter

    AUTHORIZE_URL = "https://login.xero.com/identity/connect/authorize"
    TOKEN_URL = "https://identity.xero.com/connect/token"
    CONNECTIONS_URL = "https://api.xero.com/connections"
    REVOKE_URL = "https://identity.xero.com/connect/revocation"
    TIMEOUT = 15

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
      raise Error, "Xero did not return a refresh token; reconnect and allow offline access" if data["refresh_token"].blank?

      claims = id_token_claims(data["id_token"])
      subject = claims["xero_userid"].presence || claims["sub"].presence ||
        raise(Error, "Xero did not identify the connecting user")
      tenants = fetch_tenants(data.fetch("access_token"))

      {
        external_subject_id: subject,
        external_identity: claims["email"].presence || tenants.first&.fetch("name", nil) || "Xero",
        credential_kind: "oauth2",
        credential_payload: credential_payload(data),
        credential_metadata: {
          "granted_scopes" => data["scope"].to_s.split.presence || attempt.requested_scopes,
          "tenants" => tenants,
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
          raise(Error, "Xero refresh token is unavailable; reconnect Xero")
        data = token_request(grant_type: "refresh_token", refresh_token: refresh_token)
        # Xero rotates the refresh token on every use; the old one is now dead.
        # Never fall back to it.
        raise Error, "Xero did not return a new refresh token; reconnect Xero" if data["refresh_token"].blank?

        refreshed_payload = credential_payload(data)
        connection.replace_credential_payload_without_reconciliation!(refreshed_payload)
        refreshed_payload.fetch("access_token")
      end
    end

    def revoke(connection)
      revoke!(connection)
    rescue StandardError => e
      Rails.logger.warn("Xero token revocation failed for service connection #{connection.id}: #{e.class}")
    end

    # Revoking the refresh token removes every organisation connection this
    # grant made, on Xero's side.
    def revoke!(connection)
      token = connection.credential_payload_hash["refresh_token"]
      return if token.blank?

      response = post_form(REVOKE_URL, token: token)
      raise Error, "Xero credential revocation failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
    end

    private

    def token_request(params)
      response = post_form(TOKEN_URL, params)
      if response.is_a?(Net::HTTPBadRequest) && oauth_error(response) == "invalid_grant"
        raise Error, "Xero no longer accepts this connection's refresh token (unused for 60 days, or refreshed elsewhere); reconnect Xero"
      end
      parse_success(response, "Xero OAuth token exchange")
    end

    def post_form(url, params)
      uri = URI(url)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(client_id, client_secret)
      request.set_form_data(params)
      http(uri) { |connection| connection.request(request) }
    end

    def fetch_tenants(access_token)
      uri = URI(CONNECTIONS_URL)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      request["Accept"] = "application/json"
      body = parse_success(http(uri) { |connection| connection.request(request) }, "Xero organisation lookup")
      raise Error, "Xero organisation lookup returned an unexpected shape" unless body.is_a?(Array)
      raise Error, "No Xero organisation was selected; reconnect and choose at least one" if body.empty?

      body.map do |tenant|
        {
          "id" => tenant["tenantId"].to_s,
          "name" => tenant["tenantName"].to_s,
          "type" => tenant["tenantType"].to_s
        }
      end
    end

    # The id_token comes straight from Xero's token endpoint over TLS, in the
    # same response as the tokens it describes, so the claims are read without
    # verifying the signature. They name the account; they grant nothing.
    def id_token_claims(id_token)
      return {} if id_token.blank?

      segment = id_token.to_s.split(".")[1].to_s
      JSON.parse(Base64.urlsafe_decode64(segment + ("=" * ((4 - segment.length % 4) % 4))))
    rescue ArgumentError, JSON::ParserError
      {}
    end

    def oauth_error(response)
      JSON.parse(response.body.to_s)["error"]
    rescue JSON::ParserError
      nil
    end

    def credential_payload(data)
      {
        "access_token" => data.fetch("access_token"),
        "refresh_token" => data.fetch("refresh_token"),
        "expires_at" => data["expires_in"].to_i.seconds.from_now.utc.iso8601
      }
    end

    def token_fresh?(payload)
      expires_at = Time.iso8601(payload["expires_at"].to_s)
      payload["access_token"].present? && expires_at > 1.minute.from_now
    rescue ArgumentError
      false
    end

    def http(uri, &block)
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
        open_timeout: TIMEOUT, read_timeout: TIMEOUT, max_retries: 0, &block)
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError
      raise Error, "Xero could not be reached"
    end

    def parse_success(response, label)
      raise Error, "#{label} failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)
      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "#{label} returned invalid JSON"
    end

    def client_id
      Rails.application.credentials.dig(:xero, :client_id) ||
        ENV["XERO_CLIENT_ID"] ||
        raise(ArgumentError, "Xero client_id is not configured")
    end

    def client_secret
      Rails.application.credentials.dig(:xero, :client_secret) ||
        ENV["XERO_CLIENT_SECRET"] ||
        raise(ArgumentError, "Xero client_secret is not configured")
    end

  end
end
