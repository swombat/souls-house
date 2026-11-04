require "net/http"
require "json"
require "openssl"
require "resolv"
require "ipaddr"

module Services
  # Legacy RPC slice only. The key retains its Odoo user's permissions;
  # the runtime helper's read-only commands do not attenuate that authority.
  class OdooAdapter

    MAX_RESPONSE_BYTES = 1_048_576
    NON_PUBLIC_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16
      172.16.0.0/12 192.0.0.0/24 192.0.2.0/24 192.168.0.0/16
      198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
      2001::/23 2001:db8::/32 2002::/16 3fff::/20
    ].map { |range| IPAddr.new(range) }.freeze

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      api_url = self.class.normalize_api_url(credentials["api_url"])
      database = credentials["database"].to_s.strip
      login = credentials["login"].to_s.strip
      key = credentials["api_key"].to_s.strip
      raise Error, "Odoo database, login and API key are required" if [ database, login, key ].any?(&:blank?)

      version = rpc(api_url, "common", "version", [])
      version_info = version.is_a?(Hash) && version["server_version_info"]
      major = version_info.first if version_info.is_a?(Array)
      major = major.delete_prefix("saas~").to_i if major.is_a?(String) && major.match?(/\Asaas~(?:16|17|18|19)\z/)
      unless version_info.is_a?(Array) && version_info.size >= 3 &&
             major.is_a?(Integer) && (16..19).cover?(major) &&
             version_info[1, 2].all? { |part| part.is_a?(Integer) && part >= 0 }
        raise Error, "This connector supports Odoo 16–19 numbered and SaaS releases over JSON-RPC only"
      end

      uid = rpc(api_url, "common", "authenticate", [ database, login, key, {} ])
      raise Error, "Odoo rejected this database, login or API key" unless uid.is_a?(Integer) && uid.positive?

      {
        external_subject_id: "#{api_url}|#{database}|#{uid}",
        external_identity: "#{login} (#{database})",
        label: "Odoo (#{database})",
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(key),
        credential_payload: { "api_key" => key },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "api_url" => api_url,
          "database" => database,
          "login" => login,
          "uid" => uid,
          "protocol" => "jsonrpc",
          "odoo_version" => version_info.first(3).join("."),
          "odoo_edition" => "not checked",
          "accounting_modules" => "not checked",
          "authority_summary" => "This API key carries its Odoo user's full permissions in #{database}. " \
                                 "The helper only reads, by convention; the house has not verified read-only rights. " \
                                 "Use a dedicated read-only Odoo user. Drafts, posting and payments are not helper commands."
        }
      }
    end

    def revoke(_connection)
      # Removes house access only. The owner revokes the API key in Odoo.
      true
    end

    def self.normalize_api_url(value)
      uri = URI.parse(value.to_s.strip)
      unless uri.is_a?(URI::HTTPS) && uri.host.present? && uri.userinfo.nil? &&
             uri.query.nil? && uri.fragment.nil? && [ "", "/", "/jsonrpc", "/jsonrpc/" ].include?(uri.path)
        raise Error, "Use a public https:// Odoo URL without credentials, query or fragment"
      end
      uri.host = uri.host.downcase
      uri.path = ""
      uri.to_s
    rescue URI::InvalidURIError
      raise Error, "That isn't a valid Odoo URL"
    end

    private

    def rpc(api_url, service, method, args)
      uri = URI("#{api_url}/jsonrpc")
      address = public_address_for(uri.hostname)
      request = Net::HTTP::Post.new(uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request.body = {
        jsonrpc: "2.0", method: "call", id: 1,
        params: { service: service, method: method, args: args }
      }.to_json
      # Disable ambient proxies and retries; preserve hostname for TLS/SNI.
      http = Net::HTTP.new(uri.hostname, uri.port, nil)
      http.use_ssl = true
      http.ipaddr = address
      http.open_timeout = 10
      http.read_timeout = 15
      http.write_timeout = 15
      http.max_retries = 0
      body = +""
      http.start do |connection|
        connection.request(request) do |response|
          raise Error, "Odoo refused validation (HTTP #{response.code}); check the URL and credentials" unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            raise Error, "Odoo validation response is too large" if body.bytesize + chunk.bytesize > MAX_RESPONSE_BYTES
            body << chunk
          end
        end
      end
      result = JSON.parse(body)
      unless result.is_a?(Hash) && result["jsonrpc"] == "2.0" && result["id"] == 1 &&
             !result.key?("error") && result.key?("result")
        raise Error, "Odoo could not validate this connection"
      end
      result["result"]
    rescue JSON::ParserError
      raise Error, "Odoo returned unreadable JSON"
    rescue SocketError, SystemCallError, Resolv::ResolvError, Timeout::Error, OpenSSL::SSL::SSLError,
           Net::HTTPBadResponse, EOFError, IOError
      raise Error, "Could not reach Odoo over https"
    end

    def public_address_for(host)
      addresses = resolve_addresses(host)
      raise Error, "Odoo must resolve only to public internet addresses" if addresses.empty? || !addresses.all? { |address| public_address?(address) }
      addresses.first
    end

    def resolve_addresses(host)
      return [ host ] if (IPAddr.new(host) rescue nil)
      Resolv.getaddresses(host).uniq
    end

    def public_address?(address)
      ip = IPAddr.new(address)
      ip = ip.native if ip.ipv4_mapped?
      return false if ip.ipv6? && !IPAddr.new("2000::/3").include?(ip)
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
