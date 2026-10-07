require "net/http"
require "json"
require "openssl"

module Services
  class PipedriveTokenAdapter

    DOMAIN_PATTERN = /\A[a-z0-9][a-z0-9-]{0,62}\z/

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      token = credentials["api_token"].to_s.strip
      domain = self.class.normalize_domain(credentials["company_domain"])
      raise Error, "Pipedrive API token is required" if token.blank?
      raise Error, "Company domain must be the part before .pipedrive.com" unless domain.match?(DOMAIN_PATTERN)

      me = get_json(domain, "/api/v1/users/me", token).fetch("data")
      returned_domain = me["company_domain"].to_s.downcase
      if returned_domain.present? && returned_domain != domain
        raise Error, "This token belongs to #{returned_domain}.pipedrive.com, not #{domain}.pipedrive.com"
      end

      company_name = me["company_name"].presence || domain
      email = me.fetch("email")

      {
        external_subject_id: "#{me.fetch('company_id')}:#{me.fetch('id')}",
        external_identity: email,
        label: "#{company_name} (#{email})",
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(token),
        credential_payload: {
          "api_token" => token
        },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "company_domain" => domain,
          "company_name" => company_name,
          "company_id" => me["company_id"].to_s,
          "user_id" => me["id"].to_s,
          "user_name" => me["name"],
          "api_base" => "https://#{domain}.pipedrive.com/api",
          "authority_summary" => "Acts as #{me['name'].presence || email} in #{company_name}'s Pipedrive. " \
                                 "The token carries that user's full Pipedrive permissions."
        }.compact
      }
    rescue KeyError
      raise Error, "Pipedrive returned incomplete user information"
    end

    def revoke(_connection)
      # Pipedrive API tokens cannot be revoked by a third party. The owner
      # regenerates the token in Pipedrive; souls.house removes its copy.
      true
    end

    def self.normalize_domain(value)
      value.to_s.strip.downcase
        .sub(%r{\Ahttps?://}, "")
        .sub(%r{/.*\z}, "")
        .sub(/\.pipedrive\.com\z/, "")
    end

    private

    def get_json(domain, path, token)
      uri = URI("https://#{domain}.pipedrive.com#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["x-api-token"] = token
      request["User-Agent"] = "souls.house service connection"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPUnauthorized
        raise Error, "Pipedrive rejected this API token"
      when Net::HTTPForbidden
        raise Error, "Pipedrive did not allow this token to read its own user"
      when Net::HTTPNotFound
        raise Error, "Pipedrive could not find the company #{domain}.pipedrive.com"
      else
        raise Error, "Pipedrive validation failed (#{response.code})"
      end
    rescue JSON::ParserError
      raise Error, "Pipedrive returned invalid JSON"
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
      raise Error, "Could not reach #{domain}.pipedrive.com"
    end

    def credential_fingerprint(token)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, token)
    end

  end
end
