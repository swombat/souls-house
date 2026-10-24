require "net/http"
require "json"
require "openssl"

module Services
  # TwitterAPI.io: one API key, sent as X-API-Key. GET /oapi/my/info proves
  # it without spending anything and says how many credits the account has
  # left (checked 2026-10-14: 200 with {recharge_credits, total_bonus_credits}
  # for a good key, 401 for a bad one). The key pays for the account's tweet
  # streams (FieldTweets); it can't post, and it can't spend beyond the
  # credit its owner has bought. The owner revokes it on twitterapi.io.
  class TwitterApiIoAdapter

    INFO_URL = "https://api.twitterapi.io/oapi/my/info".freeze

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      api_key = credentials["api_key"].to_s.strip
      raise Error, "TwitterAPI.io API key is required" if api_key.blank?

      info = fetch_info(api_key)
      credits = info["recharge_credits"].is_a?(Numeric) ? info["recharge_credits"].to_i : nil
      bonus = info["total_bonus_credits"].is_a?(Numeric) ? info["total_bonus_credits"].to_i : nil

      {
        external_subject_id: nil,
        external_identity: nil,
        label: "TwitterAPI.io",
        credential_kind: "api_key",
        credential_fingerprint: credential_fingerprint(api_key),
        credential_payload: { "api_key" => api_key },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "credits_at_connect" => credits,
          "bonus_credits_at_connect" => bonus,
          "authority_summary" => authority_summary(credits)
        }.compact
      }
    end

    def revoke(_connection)
      # TwitterAPI.io keys are managed by their owner on twitterapi.io;
      # the house removes its copy.
      true
    end

    private

    def authority_summary(credits)
      left = credits ? " It had #{credits} credits when connected." : ""
      "Reads public posts through TwitterAPI.io and pays for this account's tweet streams from the credit on that " \
        "account. It cannot post or reach any X account.#{left}"
    end

    def fetch_info(api_key)
      uri = URI(INFO_URL)
      request = Net::HTTP::Get.new(uri)
      request["X-API-Key"] = api_key
      request["Accept"] = "application/json"
      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 20
      http.max_retries = 0
      response = http.start { |connection| connection.request(request) }

      status = response.code.to_i
      raise Error, "TwitterAPI.io rejected this key (#{status})" if status.in?([ 401, 403 ])
      # Never the body: it may echo the request, and the request carries the key.
      raise Error, "TwitterAPI.io couldn't check this key (#{status})" unless response.is_a?(Net::HTTPSuccess)

      parsed = JSON.parse(response.body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    rescue Timeout::Error, SystemCallError, SocketError, OpenSSL::SSL::SSLError, IOError
      raise Error, "Could not reach api.twitterapi.io"
    end

    def credential_fingerprint(api_key)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, api_key)
    end

  end
end
