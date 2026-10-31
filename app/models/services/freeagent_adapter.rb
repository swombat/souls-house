require "net/http"
require "json"

module Services
  # Confidential OAuth client: the house alone holds the refresh token and
  # client secret. FreeAgent has no read-only OAuth scope or documented PKCE.
  class FreeagentAdapter

    AUTHORIZE_URL = "https://api.freeagent.com/v2/approve_app"
    TOKEN_URL = "https://api.freeagent.com/v2/token_endpoint"
    USER_URL = "https://api.freeagent.com/v2/users/me"
    COMPANY_URL = "https://api.freeagent.com/v2/company"
    USER_AGENT = "SoulsHouse FreeAgent integration"
    AUTHORITY_SUMMARY = "Acts as the approving FreeAgent user, within their FreeAgent permission level; no read-only OAuth scope."
    TIMEOUT = 15

    class Error < Services::AdapterError; end
    class DeadGrant < Error; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def authorization_url(attempt, state:, redirect_uri:)
      "#{AUTHORIZE_URL}?#{{
        response_type: "code", client_id: client_id,
        redirect_uri: redirect_uri, state: state
      }.to_query}"
    end

    def exchange_code(code:, attempt:, redirect_uri:)
      data = token_request(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri)
      payload = credential_payload(data)
      identity = fetch_resource(USER_URL, "user", payload["access_token"]).slice("url", "email", "permission_level")
      company_data = fetch_resource(COMPANY_URL, "company", payload["access_token"])
      company = company_data.slice("id", "url", "name", "company_registration_number")
      validate_identity!(identity, company_data)

      {
        # /company's URL is constant, not a company identifier. Include its
        # documented id alongside the user URL to prevent company/user switching.
        external_subject_id: [ company_data["id"].to_s, identity["url"] ].to_json,
        external_identity: [
          [ company["name"].presence || "FreeAgent", ("(#{company['company_registration_number']})" if company["company_registration_number"].present?) ].compact.join(" "),
          identity["email"].presence
        ].compact.join(" — "),
        credential_kind: "oauth2",
        credential_payload: payload,
        credential_metadata: {
          "identity" => identity,
          "company" => company,
          "authority_summary" => AUTHORITY_SUMMARY,
          "granted_scopes" => [],
          "credential_strategy" => definition.credential_strategy
        }
      }
    end

    def current_access_token(connection)
      dead = nil
      result = connection.with_lock do
        connection.reload
        raise Error, "FreeAgent connection is not connected; reconnect FreeAgent" unless connection.status == "connected"

        begin
          payload = connection.credential_payload_hash
          check_refresh_expiry!(payload)
          if token_fresh?(payload)
            payload["access_token"]
          else
            refresh!(connection, payload)["access_token"]
          end
        rescue DeadGrant => e
          # Commit the dead mark under this lock, then raise outside the
          # transaction; never clear a subsequently reconnected grant.
          connection.update!(status: "reauthorizing", credential_payload: nil)
          dead = e
          nil
        end
      end
      raise dead if dead

      result
    end

    def revoke(connection)
      revoke!(connection)
    end

    def revoke!(connection)
      # No documented remote revocation endpoint. Disconnect is local; the
      # owner can also revoke the application's access within FreeAgent.
      nil
    end

    private

    def refresh!(connection, payload)
      token = payload["refresh_token"]
      raise Error, "FreeAgent refresh token is unavailable; reconnect FreeAgent" unless token_string?(token)

      data = token_request(grant_type: "refresh_token", refresh_token: token)
      refreshed = credential_payload(data, previous: payload)
      connection.replace_credential_payload_without_reconciliation!(refreshed)
      refreshed
    end

    def token_request(params)
      uri = URI(TOKEN_URL)
      request = Net::HTTP::Post.new(uri)
      request.basic_auth(client_id, client_secret)
      request.set_form_data(params)
      response = perform(uri, request)
      if response.code.to_i.in?([ 400, 401 ]) && oauth_error(response) == "invalid_grant"
        raise DeadGrant, "FreeAgent no longer accepts this grant; reconnect FreeAgent"
      end
      parse_success(response, "FreeAgent token exchange")
    end

    def fetch_resource(url, key, access_token)
      uri = URI(url)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      data = parse_success(perform(uri, request), "FreeAgent identity lookup")
      resource = data[key]
      raise Error, "FreeAgent identity lookup returned an unexpected shape" unless resource.is_a?(Hash)

      resource
    end

    def validate_identity!(identity, company)
      valid_user = identity["url"].is_a?(String) &&
        identity["url"].match?(%r{\Ahttps://api\.freeagent\.com/v2/users/[0-9]+\z})
      valid_company = company["url"] == COMPANY_URL &&
        company["id"].to_s.match?(/\A[0-9]+\z/)
      valid_fields = identity.values.all? { |value| value.nil? || value.is_a?(String) || value.is_a?(Numeric) } &&
        company.slice("name", "company_registration_number").values.all? { |value| value.nil? || value.is_a?(String) }
      raise Error, "FreeAgent did not identify the connecting user and company" unless valid_user && valid_company && valid_fields
    end

    def credential_payload(data, previous: nil)
      access_token = data["access_token"]
      refresh_token = data.key?("refresh_token") ? data["refresh_token"] : previous&.dig("refresh_token")
      unless token_string?(access_token) && token_string?(refresh_token)
        raise Error, "FreeAgent returned incomplete credentials; reconnect FreeAgent"
      end

      now = Time.current
      payload = {
        "access_token" => access_token,
        "refresh_token" => refresh_token,
        "expires_at" => expiry(data["expires_in"], now),
        "refreshed_at" => now.utc.iso8601
      }
      if data.key?("refresh_token_expires_in")
        payload["refresh_expires_at"] = expiry(data["refresh_token_expires_in"], now)
      elsif previous&.key?("refresh_expires_at")
        # No documented promise of extension: retain the known deadline.
        payload["refresh_expires_at"] = previous["refresh_expires_at"]
      end
      payload
    end

    def expiry(seconds, now)
      unless (seconds.is_a?(Integer) || seconds.is_a?(String)) && seconds.to_s.match?(/\A[0-9]+\z/) && seconds.to_i.positive?
        raise Error, "FreeAgent returned an invalid token lifetime"
      end
      (now + seconds.to_i).utc.iso8601
    rescue ArgumentError, RangeError
      raise Error, "FreeAgent returned an invalid token lifetime"
    end

    def token_string?(value)
      value.is_a?(String) && value.present? && !value.match?(/[[:space:][:cntrl:]]/)
    end

    def check_refresh_expiry!(payload)
      return unless payload.key?("refresh_expires_at")
      if Time.iso8601(payload["refresh_expires_at"].to_s) <= Time.current
        raise DeadGrant, "FreeAgent refresh token has expired; reconnect FreeAgent"
      end
    rescue ArgumentError
      raise Error, "FreeAgent refresh token expiry is invalid; reconnect FreeAgent"
    end

    def token_fresh?(payload)
      token_string?(payload["access_token"]) && Time.iso8601(payload["expires_at"].to_s) > 1.minute.from_now
    rescue ArgumentError
      false
    end

    def oauth_error(response)
      data = JSON.parse(response.body.to_s)
      data["error"] if data.is_a?(Hash)
    rescue JSON::ParserError
      nil
    end

    def parse_success(response, label)
      raise Error, "#{label} failed (#{response.code.to_i})" unless response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body.to_s)
      raise Error, "#{label} returned an unexpected shape" unless data.is_a?(Hash)

      data
    rescue JSON::ParserError
      raise Error, "#{label} returned invalid JSON"
    end

    def perform(uri, request)
      request["User-Agent"] = USER_AGENT
      request["Accept"] = "application/json"
      Net::HTTP.start(uri.hostname, uri.port, use_ssl: true,
        open_timeout: TIMEOUT, read_timeout: TIMEOUT, write_timeout: TIMEOUT, max_retries: 0) do |http|
        http.request(request)
      end
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
           IOError, Net::ProtocolError, Net::HTTPBadResponse, ArgumentError
      raise Error, "FreeAgent could not be reached"
    end

    def client_id
      Rails.application.credentials.dig(:freeagent, :client_id).presence ||
        ENV["FREEAGENT_CLIENT_ID"].presence ||
        raise(Error, "FreeAgent client_id is not configured")
    end

    def client_secret
      Rails.application.credentials.dig(:freeagent, :client_secret).presence ||
        ENV["FREEAGENT_CLIENT_SECRET"].presence ||
        raise(Error, "FreeAgent client_secret is not configured")
    end

  end
end
