require "net/http"
require "json"

module Services
  # Withings (scales, watches, blood-pressure cuffs) over OAuth 2.0.
  #
  # Withings is not quite standard OAuth: the token endpoint takes
  # `action=requesttoken`, always answers HTTP 200, and wraps the result as
  # {"status": 0, "body": {...}}, so a non-zero status is the error. Access
  # tokens are short-lived (expires_in, a few hours) and each refresh answers
  # with a new refresh token, which is saved every time.
  class WithingsAdapter

    AUTHORIZE_URL = "https://account.withings.com/oauth2_user/authorize2"
    TOKEN_URL = "https://wbsapi.withings.net/v2/oauth2"

    # How long a handed-out token must still be good for. Withings tokens live
    # hours, not days, so Oura's one-day margin would refresh on every request.
    FRESHNESS_MARGIN = 15.minutes

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def authorization_url(attempt, state:, redirect_uri:)
      params = {
        response_type: "code",
        client_id: client_id,
        redirect_uri: redirect_uri,
        # Withings separates scopes with commas, not spaces.
        scope: attempt.requested_scopes.join(","),
        state: state
      }
      "#{AUTHORIZE_URL}?#{params.to_query}"
    end

    def exchange_code(code:, attempt:, redirect_uri:)
      data = token_request(
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri
      )
      user_id = data["userid"].to_s.presence || raise(Error, "Withings token exchange returned no user id")

      {
        external_subject_id: user_id,
        external_identity: attempt.user.email_address,
        match_existing_by: :connected_user,
        credential_kind: "oauth2",
        credential_payload: credential_payload(data),
        credential_metadata: {
          "granted_scopes" => data["scope"].to_s.split(",").map(&:strip).presence || attempt.requested_scopes,
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
          raise(Error, "Withings refresh token is unavailable; reconnect Withings")
        data = token_request(grant_type: "refresh_token", refresh_token: refresh_token)
        refreshed_payload = credential_payload(data, previous_refresh_token: refresh_token)
        connection.replace_credential_payload_without_reconciliation!(refreshed_payload)
        refreshed_payload.fetch("access_token")
      end
    end

    # Withings' revoke call needs a signed nonce round trip that the house does
    # not implement yet. Disconnecting deletes the house's tokens; the person
    # can also remove the app from their Withings account.
    def revoke(_connection)
      nil
    end

    private

    def token_request(params)
      response = Net::HTTP.post_form(URI(TOKEN_URL), params.merge(
        action: "requesttoken",
        client_id: client_id,
        client_secret: client_secret
      ))
      parse_success(response, "Withings token exchange")
    end

    def credential_payload(data, previous_refresh_token: nil)
      {
        "access_token" => data.fetch("access_token"),
        "refresh_token" => data["refresh_token"].presence || previous_refresh_token,
        "expires_at" => data["expires_in"].to_i.seconds.from_now.utc.iso8601,
        "userid" => data["userid"].to_s.presence
      }.compact
    rescue KeyError
      raise Error, "Withings token response had no access token"
    end

    def token_fresh?(payload)
      expires_at = Time.iso8601(payload["expires_at"].to_s)
      payload["access_token"].present? && expires_at > FRESHNESS_MARGIN.from_now
    rescue ArgumentError
      false
    end

    def parse_success(response, label)
      raise Error, "#{label} failed (HTTP #{response.code})" unless response.is_a?(Net::HTTPSuccess)

      json = JSON.parse(response.body)
      status = json["status"]
      unless status == 0 && json["body"].is_a?(Hash)
        detail = json["error"].to_s.presence
        raise Error, ["#{label} failed (Withings status #{status.inspect})", detail].compact.join(": ")
      end
      json["body"]
    rescue JSON::ParserError
      raise Error, "#{label} returned invalid JSON"
    end

    def client_id
      Rails.application.credentials.dig(:withings, :client_id) ||
        raise(ArgumentError, "Withings client_id is not configured")
    end

    def client_secret
      Rails.application.credentials.dig(:withings, :client_secret) ||
        raise(ArgumentError, "Withings client_secret is not configured")
    end

  end
end
