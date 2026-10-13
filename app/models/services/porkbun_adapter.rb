require "net/http"
require "json"
require "openssl"

module Services
  # Porkbun's v3 API takes an API key and a secret API key in the JSON body of
  # every POST. /ping proves the pair and names the account; /domain/listAll
  # gives the domains it can see, for the label. A key carries scopes (read,
  # dns, domains, purchase, funding, ...; "full" is all of them), and the
  # authority summary says which, because a full key can spend money.
  # Porkbun has no way for a third party to revoke a key: the owner deletes it.
  class PorkbunAdapter

    API_BASE = "https://api.porkbun.com/api/json/v3".freeze
    LABEL_DOMAINS = 3
    SPENDING_SCOPES = %w[full purchase funding].freeze

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      api_key = credentials["api_key"].to_s.strip
      secret_key = credentials["secret_key"].to_s.strip
      raise Error, "Porkbun API key is required" if api_key.blank?
      raise Error, "Porkbun secret API key is required" if secret_key.blank?
      raise Error, "The API key starts pk1_ and the secret key sk1_; they look swapped" if api_key.start_with?("sk1_") && secret_key.start_with?("pk1_")

      ping = post_json("/ping", api_key, secret_key)
      account = ping["account"].to_s.presence
      scopes = Array(ping["scopes"]).map(&:to_s)
      domains = Array(post_json("/domain/listAll", api_key, secret_key)["domains"]).filter_map { |domain| domain["domain"].presence }.sort

      {
        external_subject_id: nil,
        external_identity: account,
        label: label_for(account, domains),
        credential_kind: "api_key_pair",
        credential_fingerprint: credential_fingerprint(api_key),
        credential_payload: {
          "api_key" => api_key,
          "secret_key" => secret_key
        },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "account" => account,
          "key_scopes" => scopes,
          "domains" => domains,
          "api_base" => API_BASE,
          "authority_summary" => authority_summary(account, scopes, domains)
        }.compact
      }
    end

    def revoke(_connection)
      # Porkbun keys cannot be revoked by a third party. The owner deletes the
      # key under Account → API Access; souls.house removes its copy.
      true
    end

    private

    def authority_summary(account, scopes, domains)
      where = "#{domain_phrase(domains)} in #{account ? "the #{account}" : 'this'} Porkbun account"
      if scopes.empty?
        "Porkbun didn't say what this key may do on #{where}. Assume it may be able to buy domains and add credit " \
          "as well as change DNS; a key made with only the dns scope rules that out."
      elsif scopes.include?("full")
        "Full access to #{where}: DNS, URL forwards and nameservers, and also buying, renewing and transferring " \
          "domains and adding credit. Make a key with only the dns scope if residents should not spend money."
      elsif scopes.intersect?(SPENDING_SCOPES)
        "Scopes #{scopes.join(', ')} on #{where}. The purchase or funding scope lets it spend money."
      else
        "Scopes #{scopes.join(', ')} on #{where}. It cannot buy domains or add credit."
      end
    end

    def label_for(account, domains)
      name = account ? "Porkbun (#{account})" : "Porkbun"
      return name if domains.empty?

      shown = domains.first(LABEL_DOMAINS).join(", ")
      more = domains.size - LABEL_DOMAINS
      "#{name}: #{shown}#{more.positive? ? " and #{more} more" : ''}"
    end

    def domain_phrase(domains)
      case domains.size
      when 0 then "the domains"
      when 1 then domains.first
      else "#{domains.size} domains"
      end
    end

    def post_json(path, api_key, secret_key)
      uri = URI("#{API_BASE}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Accept"] = "application/json"
      request["Content-Type"] = "application/json"
      request["User-Agent"] = "souls.house service connection"
      request.body = { apikey: api_key, secretapikey: secret_key }.to_json
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 20) do |http|
        http.request(request)
      end

      body = parse(response.body)
      return body if response.is_a?(Net::HTTPSuccess) && body["status"] == "SUCCESS"

      message = body["message"].to_s
      if message.match?(/invalid api key/i) || response.code.to_i.in?([ 401, 403 ])
        raise Error, "Porkbun rejected this key pair (#{message.presence || response.code})"
      end

      raise Error, "Porkbun validation failed (#{message.presence || response.code})"
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
      raise Error, "Could not reach api.porkbun.com"
    end

    def parse(body)
      parsed = JSON.parse(body.to_s)
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end

    def credential_fingerprint(api_key)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, api_key)
    end

  end
end
