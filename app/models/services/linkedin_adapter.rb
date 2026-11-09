require "net/http"
require "json"

module Services
  # A LinkedIn member profile, for posting (Share on LinkedIn, self-serve:
  # scopes openid profile w_member_social).
  #
  # Member access tokens last 60 days and LinkedIn gives refresh tokens only
  # to approved partners, so for most apps the grant simply ends: the owner
  # reconnects (an ordinary Connect again, which matches this connection by
  # the OIDC subject). LinkedinGrantExpiryJob warns the owner a week ahead
  # and again at expiry. If LinkedIn does return a refresh token, it is used.
  #
  # Residents never hold the token (credential_strategy "house_poster"):
  # every post goes through LinkedinPoster, which checks the resident's
  # access and keeps an idempotent record of what was published.
  class LinkedinAdapter

    AUTHORIZE_URL = "https://www.linkedin.com/oauth/v2/authorization"
    TOKEN_URL = "https://www.linkedin.com/oauth/v2/accessToken"
    REVOKE_URL = "https://www.linkedin.com/oauth/v2/revoke"
    USERINFO_URL = "https://api.linkedin.com/v2/userinfo"
    FRESHNESS_MARGIN = 5.minutes
    TIMEOUT = 20

    class Error < Services::AdapterError; end

    # The grant has ended and nothing the house holds can renew it. `token`
    # is the access token that was found ended, so a caller repairing state
    # later can tell whether the connection still holds that grant.
    class Expired < Error

      attr_reader :token

      def initialize(message = nil, token: nil)
        @token = token
        super(message)
      end

    end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def authorization_url(attempt, state:, redirect_uri:)
      params = {
        response_type: "code",
        client_id: client_id,
        redirect_uri: redirect_uri,
        scope: attempt.requested_scopes.join(" "),
        state: state
      }
      "#{AUTHORIZE_URL}?#{params.to_query}"
    end

    def exchange_code(code:, attempt:, redirect_uri:)
      data = token_request(grant_type: "authorization_code", code: code, redirect_uri: redirect_uri)
      identity = fetch_identity(data["access_token"])
      subject = identity["sub"]
      raise Error, "LinkedIn did not say which member signed in" unless subject.is_a?(String) && subject.match?(/\A[A-Za-z0-9_-]{1,100}\z/)

      name = identity["name"].presence || [ identity["given_name"], identity["family_name"] ].compact.join(" ").presence

      {
        external_subject_id: subject,
        external_identity: name.is_a?(String) ? name.truncate(200) : attempt.user.email_address,
        credential_kind: "oauth2",
        credential_payload: credential_payload(data).merge("author_urn" => "urn:li:person:#{subject}"),
        credential_metadata: {
          "granted_scopes" => data["scope"].to_s.split(/[\s,]+/).presence || attempt.requested_scopes,
          "credential_strategy" => definition.credential_strategy
        }
      }
    end

    # A token good for at least FRESHNESS_MARGIN, refreshed if LinkedIn gave
    # this app a refresh token. When the grant has ended, the connection is
    # marked reauthorizing (so the card says Reconnect) and Expired is raised
    # with a sentence a resident can repeat to the owner.
    def current_access_token(connection)
      expired = nil
      token = connection.with_lock do
        connection.reload
        raise Error, "The LinkedIn connection is not connected; the owner reconnects it from Integrations" unless connection.status == "connected"

        payload = connection.credential_payload_hash
        if fresh?(payload["access_token"], payload["expires_at"])
          payload["access_token"]
        elsif payload["refresh_token"].present? && fresh?(payload["refresh_token"], payload["refresh_token_expires_at"], allow_missing_expiry: true)
          begin
            response = token_request(grant_type: "refresh_token", refresh_token: payload["refresh_token"])
          rescue Expired => e
            raise Expired.new(e.message, token: payload["access_token"])
          end
          refreshed = credential_payload(response, previous: payload)
          connection.replace_credential_payload_without_reconciliation!(refreshed)
          refreshed["access_token"]
        else
          connection.update!(status: "reauthorizing")
          expired = Expired.new(self.class.expired_message(grant_expires_at(connection)), token: payload["access_token"])
          nil
        end
      end
      raise expired if expired

      token
    end

    def author_urn(connection)
      connection.credential_payload_hash["author_urn"].presence ||
        (connection.external_subject_id.presence && "urn:li:person:#{connection.external_subject_id}") ||
        raise(Error, "The LinkedIn connection has no member id; reconnect it")
    end

    # When the owner will next have to reconnect: the refresh token's end if
    # there is one, otherwise the access token's.
    def grant_expires_at(connection)
      payload = connection.credential_payload_hash
      value = payload["refresh_token"].present? ? (payload["refresh_token_expires_at"] || payload["expires_at"]) : payload["expires_at"]
      Time.iso8601(value.to_s)
    rescue ArgumentError
      nil
    end

    def self.expired_message(expires_at)
      ended = expires_at ? " on #{expires_at.utc.strftime('%-d %b %Y')}" : ""
      "The LinkedIn sign-in for this connection ended#{ended} (LinkedIn member sign-ins last 60 days). " \
        "The account owner reconnects LinkedIn from Integrations; nothing was posted."
    end

    def revoke(connection)
      token = connection.credential_payload_hash["access_token"]
      return if token.blank?

      Net::HTTP.post_form(URI(REVOKE_URL), token: token, client_id: client_id, client_secret: client_secret)
    rescue StandardError => e
      Rails.logger.warn("LinkedIn token revocation failed for service connection #{connection.id}: #{e.class}")
    end

    private

    def fresh?(token, expires_at, allow_missing_expiry: false)
      return false if token.blank?
      return allow_missing_expiry if expires_at.blank?

      Time.iso8601(expires_at.to_s) > FRESHNESS_MARGIN.from_now
    rescue ArgumentError
      false
    end

    def token_request(params)
      uri = URI(TOKEN_URL)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(params.merge(client_id: client_id, client_secret: client_secret))
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.request(request) }
      data = parse(response)
      unless response.is_a?(Net::HTTPSuccess) && data["access_token"].is_a?(String)
        detail = [ data["error"], data["error_description"] ].select { |part| part.is_a?(String) }.join(": ").truncate(200)
        if data["error"] == "invalid_grant" && params[:grant_type] == "refresh_token"
          raise Expired, "LinkedIn refused the refresh token (#{detail}). The account owner reconnects LinkedIn from Integrations."
        end

        raise Error, "LinkedIn token exchange failed (HTTP #{response.code})#{": #{detail}" if detail.present?}"
      end
      data
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "LinkedIn could not be reached (#{e.class.name.demodulize})"
    end

    def fetch_identity(access_token)
      raise Error, "LinkedIn token response had no access token" unless access_token.is_a?(String)

      uri = URI(USERINFO_URL)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{access_token}"
      response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: TIMEOUT, read_timeout: TIMEOUT) { |http| http.request(request) }
      raise Error, "LinkedIn identity lookup failed (HTTP #{response.code}); the openid and profile scopes are needed" unless response.is_a?(Net::HTTPSuccess)

      parse(response)
    rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "LinkedIn could not be reached (#{e.class.name.demodulize})"
    end

    def credential_payload(data, previous: {})
      payload = {
        "access_token" => data.fetch("access_token"),
        "expires_at" => data["expires_in"].to_i.positive? ? data["expires_in"].to_i.seconds.from_now.utc.iso8601 : nil,
        "refresh_token" => data["refresh_token"].presence || previous["refresh_token"],
        "refresh_token_expires_at" => if data["refresh_token_expires_in"].to_i.positive?
                                        data["refresh_token_expires_in"].to_i.seconds.from_now.utc.iso8601
                                      else
                                        previous["refresh_token_expires_at"]
                                      end,
        "author_urn" => previous["author_urn"]
      }
      payload.compact
    rescue KeyError
      raise Error, "LinkedIn token response had no access token"
    end

    def parse(response)
      parsed = JSON.parse(response.body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def client_id
      Rails.application.credentials.dig(:linkedin, :client_id) ||
        raise(ArgumentError, "LinkedIn client_id is not configured")
    end

    def client_secret
      Rails.application.credentials.dig(:linkedin, :client_secret) ||
        raise(ArgumentError, "LinkedIn client_secret is not configured")
    end

  end
end
