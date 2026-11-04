require "net/http"
require "json"
require "openssl"
require "resolv"
require "ipaddr"

module Services
  # A person-supplied instance and key, not a house proxy. Validation proves
  # a bounded read, not the absence of write permissions on the key.
  class TwentyAdapter

    NON_PUBLIC_RANGES = GhostAdapter::NON_PUBLIC_RANGES

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      api_url = self.class.normalize_api_url(credentials["api_url"])
      key = credentials["api_key"].to_s.strip
      raise Error, "Twenty API URL is required" if api_url.blank?
      raise Error, "Twenty API key is required" if key.blank?
      unless key.ascii_only? && !key.match?(/[[:space:][:cntrl:]]/)
        raise Error, "Twenty API key must contain only printable ASCII without whitespace"
      end

      # Supported by the core REST API; selects IDs only, without expanding
      # related records. There is no write or permission probe.
      result = get_json("#{api_url}/rest/people?limit=1&depth=0&fields=id", key)
      people = result.dig("data", "people") if result["data"].is_a?(Hash)
      unless people.is_a?(Array) && people.all? { |person| person.is_a?(Hash) && person["id"].is_a?(String) }
        raise Error, "Twenty returned incomplete people information"
      end

      {
        external_subject_id: api_url,
        external_identity: api_url,
        label: "Twenty (#{URI(api_url).host})",
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(key),
        credential_payload: { "api_key" => key },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "api_url" => api_url,
          "api_base" => "#{api_url}/rest",
          "authority_summary" => "Carries this API key's actual Twenty workspace permissions, which may include " \
                                 "creating, updating and deleting records. Validation confirmed a people read only; " \
                                 "it did not inspect the key's role or prove read-only access. The helper offers " \
                                 "reads only, a convention rather than a restriction on the supplied key."
        }
      }
    end

    def revoke(_connection)
      # Removes the house's copy; the owner must revoke the key in Twenty.
      true
    end

    def self.normalize_api_url(value)
      raw = value.to_s.strip
      return nil if raw.blank?

      raw = "https://#{raw}" unless raw.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
      uri = URI.parse(raw)
      raise Error, "The Twenty API URL must start with https://" unless uri.scheme&.downcase == "https"
      raise Error, "The Twenty API URL needs a host name" if uri.host.blank?
      raise Error, "The Twenty API URL can't carry a user name or password" if uri.userinfo.present?
      raise Error, "The Twenty API URL can't carry a query or fragment" if uri.query || uri.fragment
      # Keep subdirectory installations, but no ambiguous dot/encoded paths.
      path = uri.path.to_s.chomp("/").sub(%r{/rest\z}, "")
      raise Error, "Use the Twenty instance URL, without an API path" unless path.match?(%r{\A(?:/[a-zA-Z0-9_-]+)*\z})

      port = uri.port == 443 ? "" : ":#{uri.port}"
      "https://#{uri.host.downcase}#{port}#{path}"
    rescue URI::InvalidURIError
      raise Error, "That isn't a valid Twenty API URL", cause: nil
    end

    private

    def get_json(url, key)
      uri = URI(url)
      address = public_address_for(uri.host)
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{key}"
      request["User-Agent"] = "souls.house service connection"

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = true
      http.ipaddr = address
      http.open_timeout = 10
      http.read_timeout = 15
      http.max_retries = 0
      response = http.start { |connection| connection.request(request) }

      case response
      when Net::HTTPSuccess
        body = JSON.parse(response.body)
        raise Error, "Twenty returned an unreadable answer" unless body.is_a?(Hash)

        body
      when Net::HTTPRedirection
        raise Error, "Twenty redirects; reconnect using the instance's current public HTTPS URL"
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        raise Error, "Twenty rejected this key or did not allow it to read people"
      when Net::HTTPNotFound
        raise Error, "No Twenty people API was found; check the instance URL"
      else
        raise Error, "Twenty validation failed (HTTP #{response.code})"
      end
    rescue JSON::ParserError, TypeError
      raise Error, "Twenty returned an unreadable answer", cause: nil
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, EOFError
      raise Error, "Could not reach the Twenty instance over https", cause: nil
    end

    # Same public-address policy as Ghost. Check every answer, then pin the
    # connection while retaining the original hostname for TLS verification.
    def public_address_for(host)
      addresses = resolve_addresses(host)
      raise Error, "Could not find the Twenty instance" if addresses.empty?
      raise Error, "The Twenty instance is not on the public internet" unless addresses.all? { |address| public_address?(address) }

      addresses.first
    end

    def resolve_addresses(host)
      return [ host ] if (IPAddr.new(host) rescue nil)

      Resolv.getaddresses(host).uniq
    end

    def public_address?(address)
      ip = IPAddr.new(address.to_s.delete_prefix("[").delete_suffix("]"))
      ip = ip.native if ip.ipv4_mapped?
      NON_PUBLIC_RANGES.none? { |range| range.family == ip.family && range.include?(ip) }
    rescue IPAddr::Error
      false
    end

    def credential_fingerprint(key)
      secret = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", secret, key)
    end

  end
end
