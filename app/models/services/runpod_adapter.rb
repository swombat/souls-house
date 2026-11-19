require "net/http"
require "json"
require "openssl"

module Services
  class RunpodAdapter

    # RunPod's GraphQL API answers `myself` for any valid key, read-only or
    # not; it is also where account balance lives (REST v2 has no user route).
    GRAPHQL_URL = "https://api.runpod.io/graphql".freeze
    REST_BASE = "https://api.runpod.io/v2".freeze

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      key = credentials["api_key"].to_s.strip
      raise Error, "RunPod API key is required" if key.blank?

      me = myself(key)
      id = me["id"].to_s
      raise Error, "RunPod returned no account for this key" if id.blank?
      identity = me["email"].presence || id

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
          "api_base" => REST_BASE,
          "graphql_url" => GRAPHQL_URL,
          "authority_summary" => "Acts as #{identity} on RunPod with whatever permissions the key was given. " \
                                 "A key with write access can start GPU pods and serverless endpoints that bill the account until stopped."
        }
      }
    end

    def revoke(_connection)
      # RunPod keys are deleted by their owner under Settings → API Keys;
      # souls.house removes its copy.
      true
    end

    private

    def myself(key)
      body = post_graphql(key, "query { myself { id email } }")
      if body["errors"].present?
        raise Error, "RunPod refused the account query: #{Array(body['errors']).map { |e| e['message'] }.compact.join('; ').presence || 'unknown error'}"
      end
      body.dig("data", "myself") || raise(Error, "RunPod returned no account for this key")
    end

    def post_graphql(key, query)
      uri = URI(GRAPHQL_URL)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{key}"
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["User-Agent"] = "souls.house service connection"
      request.body = { query: query }.to_json
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        JSON.parse(response.body)
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        raise Error, "RunPod rejected this API key"
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
