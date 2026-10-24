require "net/http"
require "json"
require "openssl"

module Services
  class HoneybadgerTokenAdapter

    # Honeybadger hosts US and EU data separately; a personal auth token is
    # only valid on the region its user lives in, so validation tries each.
    REGIONS = {
      "us" => "https://app.honeybadger.io",
      "eu" => "https://eu-app.honeybadger.io"
    }.freeze

    class Error < Services::AdapterError; end
    class Rejected < Error; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      token = credentials["auth_token"].to_s.strip
      raise Error, "Honeybadger personal auth token is required" if token.blank?

      region, origin, accounts = detect_region(token)
      raise Error, "This token has no Honeybadger accounts" if accounts.empty?

      account_ids = accounts.map { |account| account.fetch("id").to_s }.sort
      account_names = accounts.map { |account| account["name"].presence || account.fetch("id").to_s }
      identity = accounts.first["email"].presence || account_names.first

      {
        external_subject_id: account_ids.join(","),
        external_identity: identity,
        label: "Honeybadger (#{account_names.join(', ')})",
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(token),
        credential_payload: {
          "auth_token" => token
        },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "region" => region,
          "api_base" => "#{origin}/v2",
          "account_ids" => account_ids.join(","),
          "account_names" => account_names.join(", "),
          "authority_summary" => "Acts as the token's owner across #{account_names.join(', ')}. " \
                                 "A personal auth token carries that user's full Honeybadger permissions, including changes."
        }.compact
      }
    rescue KeyError
      raise Error, "Honeybadger returned incomplete account information"
    end

    def revoke(_connection)
      # Honeybadger personal auth tokens are reset by their owner under
      # User settings → Authentication; souls.house removes its copy.
      true
    end

    private

    def detect_region(token)
      REGIONS.each do |region, origin|
        body = get_json(origin, "/v2/accounts", token)
        return [ region, origin, Array(body["results"]) ]
      rescue Rejected
        next
      end
      raise Error, "Honeybadger rejected this auth token (tried the US and EU regions)"
    end

    def get_json(origin, path, token)
      uri = URI("#{origin}#{path}")
      request = Net::HTTP::Get.new(uri)
      request.basic_auth(token, "")
      request["Accept"] = "application/json"
      request["User-Agent"] = "souls.house service connection"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        raise Rejected, "Honeybadger rejected this auth token"
      else
        raise Error, "Honeybadger validation failed (#{response.code})"
      end
    rescue JSON::ParserError
      raise Error, "Honeybadger returned invalid JSON"
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
      raise Error, "Could not reach #{uri.hostname}"
    end

    def credential_fingerprint(token)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, token)
    end

  end
end
