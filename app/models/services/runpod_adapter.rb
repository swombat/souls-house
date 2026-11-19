require "net/http"
require "json"
require "openssl"

module Services
  class RunpodAdapter

    # REST v2. GET /v2/account needs the account:read scope and returns the
    # key's account { id, email|null }. GraphQL retires in early 2027.
    API_BASE = "https://api.runpod.io/v2".freeze

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      key = credentials["api_key"].to_s.strip
      raise Error, "RunPod API key is required" if key.blank?

      account = get_json("/account", key)
      id = account.is_a?(Hash) ? account["id"] : nil
      raise Error, "RunPod returned no account for this key" unless id.is_a?(String) && id.present?
      email = account["email"]
      identity = (email.is_a?(String) && email.present?) ? email : id

      {
        external_subject_id: id,
        external_identity: identity,
        label: "RunPod (#{identity})",
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(key),
        credential_payload: {
          "api_key" => key
        },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "api_base" => API_BASE,
          "authority_summary" => "Acts as #{identity} on RunPod with whatever permissions the key was given. " \
                                 "A key that can write pods can start GPUs that bill the account until terminated; souls.house sets no spend cap."
        }
      }
    end

    def revoke(_connection)
      # RunPod keys are deleted by their owner under Settings → API Keys;
      # souls.house removes its copy. Resources already started keep running.
      true
    end

    private

    def get_json(path, key)
      uri = URI("#{API_BASE}#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{key}"
      request["Accept"] = "application/json"
      request["User-Agent"] = "souls.house service connection"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPUnauthorized
        raise Error, "RunPod rejected this API key"
      when Net::HTTPForbidden
        raise Error, "RunPod accepted this key but it can't read the account. Give it account read access (or use an All key) and try again"
      else
        raise Error, "RunPod validation failed (#{response.code})"
      end
    rescue JSON::ParserError
      raise Error, "RunPod returned invalid JSON"
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
      raise Error, "Could not reach #{uri.hostname}"
    end

    def credential_fingerprint(key)
      secret = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", secret, key)
    end

  end
end
