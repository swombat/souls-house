require "net/http"
require "json"

module Services
  # A Monzo personal account, read-only, through the house.
  #
  # Monzo's developer API has no OAuth scopes: an access token can do
  # everything the API offers, including moving money between the account
  # and its pots. So read-only is enforced here, not by Monzo. Residents
  # never receive a token; they call the house's read proxy, which forwards
  # only the GET paths in READ_PATHS (credential_strategy "read_proxy").
  #
  # Monzo refresh tokens are single use ("refreshing is a one-time
  # operation"), so, as with Xero, the house is the only holder and refreshes
  # under the connection's row lock.
  #
  # Monzo's developer clients only reach the account of whoever registered
  # the client and a few users they allow, so the house's Monzo client is
  # registered by the person who connects. The service is listed only once
  # monzo.client_id and monzo.client_secret are in the credentials.
  class MonzoAdapter

    AUTHORIZE_URL = "https://auth.monzo.com/"
    API_ORIGIN = "https://api.monzo.com"
    TOKEN_URL = "#{API_ORIGIN}/oauth2/token"
    LOGOUT_URL = "#{API_ORIGIN}/oauth2/logout"
    TIMEOUT = 15

    # The only calls a resident can make. Everything else (pot deposits and
    # withdrawals, feed items, annotations, attachments, receipts, webhooks)
    # writes, and is refused before it reaches Monzo.
    READ_PATHS = [
      %r{\Aping/whoami\z},
      %r{\Aaccounts\z},
      %r{\Abalance\z},
      %r{\Apots\z},
      %r{\Atransactions\z},
      %r{\Atransactions/tx_[A-Za-z0-9]+\z}
    ].freeze

    class Error < Services::AdapterError; end
    # Monzo refused the refresh token. Nothing the house holds can revive
    # the connection; the person has to connect again.
    class DeadGrant < Error; end

    Response = Struct.new(:status, :body, keyword_init: true)

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def self.readable_path?(path)
      READ_PATHS.any? { |pattern| pattern.match?(path.to_s) }
    end

    def authorization_url(attempt, state:, redirect_uri:)
      "#{AUTHORIZE_URL}?#{{
        client_id: client_id,
        redirect_uri: redirect_uri,
        response_type: "code",
        state: state
      }.to_query}"
    end

    # The new token has no permissions until the person approves access in
    # the Monzo app (strong customer authentication), so nothing is read
    # here: the identity is the user_id from the token response.
    def exchange_code(code:, attempt:, redirect_uri:)
      data = token_request(
        grant_type: "authorization_code",
        code: code,
        redirect_uri: redirect_uri
      )
      raise Error, "Monzo did not return a refresh token; check the Monzo client is confidential" if data["refresh_token"].blank?

      subject = data["user_id"].presence || raise(Error, "Monzo did not identify the connecting user")

      {
        external_subject_id: subject,
        external_identity: attempt.user.email_address,
        match_existing_by: :connected_user,
        credential_kind: "oauth2",
        credential_payload: credential_payload(data),
        credential_metadata: {
          "granted_scopes" => [],
          "credential_strategy" => definition.credential_strategy
        }
      }
    end

    def current_access_token(connection)
      under_lock(connection) do |payload|
        next payload.fetch("access_token") if token_fresh?(payload)

        refresh!(connection, payload).fetch("access_token")
      end
    end

    # Forwards one read to Monzo. path must already have passed
    # readable_path?; this checks again so no caller can skip it.
    def read(connection, path:, query:)
      raise ArgumentError, "Not a readable Monzo path" unless self.class.readable_path?(path)

      token = current_access_token(connection)
      uri = URI("#{API_ORIGIN}/#{path}")
      uri.query = query.presence && query.to_query
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{token}"
      request["Accept"] = "application/json"
      response = http(uri) { |client| client.request(request) }
      Response.new(status: response.code.to_i, body: response.body.to_s)
    end

    def revoke(connection)
      token = connection.credential_payload_hash["access_token"]
      return if token.blank?

      uri = URI(LOGOUT_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{token}"
      http(uri) { |client| client.request(request) }
    rescue StandardError => e
      Rails.logger.warn("Monzo logout failed for service connection #{connection.id}: #{e.class}")
    end

    private

    def refresh!(connection, payload)
      refresh_token = payload["refresh_token"].presence ||
        raise(Error, "Monzo refresh token is unavailable; reconnect Monzo")
      data = token_request(grant_type: "refresh_token", refresh_token: refresh_token)
      # Refreshing is one-time: the old refresh token is dead now.
      raise Error, "Monzo did not return a new refresh token; reconnect Monzo" if data["refresh_token"].blank?

      refreshed_payload = credential_payload(data)
      connection.replace_credential_payload_without_reconciliation!(refreshed_payload)
      refreshed_payload
    end

    # As XeroAdapter#under_lock: a dead grant marks the connection
    # "reauthorizing" under the same lock that read the dead token.
    def under_lock(connection)
      dead = nil
      result = connection.with_lock do
        connection.reload
        begin
          yield connection.credential_payload_hash
        rescue DeadGrant => e
          connection.update!(status: "reauthorizing", credential_payload: nil)
          dead = e
          nil
        end
      end
      raise dead if dead

      result
    end

    def token_request(params)
      uri = URI(TOKEN_URL)
      request = Net::HTTP::Post.new(uri)
      request.set_form_data(params.merge(client_id: client_id, client_secret: client_secret))
      response = http(uri) { |client| client.request(request) }
      if params[:grant_type] == "refresh_token" && dead_refresh?(response)
        raise DeadGrant, "Monzo no longer accepts this connection's refresh token; reconnect Monzo"
      end
      raise Error, "Monzo token exchange failed (#{response.code})" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "Monzo token exchange returned invalid JSON"
    end

    # Monzo answers a used or revoked refresh token with an error code such
    # as "unauthorized.bad_refresh_token" (OAuth's "invalid_grant" is
    # accepted too). Any other refusal (a bad client secret, an outage) marks
    # nothing: the grant may still be good.
    def dead_refresh?(response)
      return false unless [ 400, 401 ].include?(response.code.to_i)

      body = JSON.parse(response.body.to_s)
      return false unless body.is_a?(Hash)

      body["error"] == "invalid_grant" || body["code"].to_s.include?("refresh_token")
    rescue JSON::ParserError
      false
    end

    def credential_payload(data)
      {
        "access_token" => data.fetch("access_token"),
        "refresh_token" => data.fetch("refresh_token"),
        "expires_at" => data["expires_in"].to_i.seconds.from_now.utc.iso8601,
        "refreshed_at" => Time.current.utc.iso8601
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
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError,
           IOError, Net::ProtocolError, Net::HTTPBadResponse
      raise Error, "Monzo could not be reached"
    end

    def client_id
      Rails.application.credentials.dig(:monzo, :client_id) ||
        raise(ArgumentError, "Monzo client_id is not configured")
    end

    def client_secret
      Rails.application.credentials.dig(:monzo, :client_secret) ||
        raise(ArgumentError, "Monzo client_secret is not configured")
    end

  end
end
