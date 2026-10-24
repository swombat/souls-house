require "net/http"
require "json"
require "openssl"
require "base64"
require "resolv"
require "ipaddr"

module Services
  # A Ghost site's Admin API key ("id:secret", from a custom integration or a
  # staff access token). Ghost has no token endpoint: every Admin API call
  # carries a five-minute HS256 JWT the caller signs with the secret. The
  # house signs one to prove the key on the site, then hands residents the
  # key and the site's API URL; soulshouse-ghost signs its own.
  #
  # The API URL is whatever the person typed, so the house only calls it over
  # https, on a public address, pinned to the address it checked.
  class GhostAdapter

    KEY_PATTERN = /\A(?<id>[0-9a-f]{6,64}):(?<secret>(?:[0-9a-f]{2}){16,64})\z/i
    ACCEPT_VERSION = "v5.0".freeze
    # Loopback, private, link-local, carrier-grade NAT (the tailnet), benchmark,
    # multicast and reserved space: nothing the house should call for a
    # person-supplied URL.
    NON_PUBLIC_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24
      192.168.0.0/16 198.18.0.0/15 224.0.0.0/3 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    class Error < Services::AdapterError; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      api_url = self.class.normalize_api_url(credentials["api_url"])
      key = credentials["admin_api_key"].to_s.strip
      raise Error, "Ghost API URL is required" if api_url.blank?
      raise Error, "Ghost Admin API key is required" if key.blank?

      match = KEY_PATTERN.match(key)
      raise Error, "That isn't a Ghost Admin API key: it should look like 24 hex characters, a colon, then 64 more" unless match

      site = get_json(api_url, "/site/", key).fetch("site", {})
      # /site/ answers anyone; a post list needs the key.
      get_json(api_url, "/posts/?limit=1&fields=id", key)

      title = site["title"].presence || URI(api_url).host
      site_url = site["url"].presence&.chomp("/") || api_url

      {
        external_subject_id: "#{URI(api_url).host}:#{match[:id].downcase}",
        external_identity: site_url,
        label: "Ghost (#{title})",
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(key),
        credential_payload: {
          "admin_api_key" => key
        },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "api_url" => api_url,
          "api_base" => "#{api_url}/ghost/api/admin",
          "site_url" => site_url,
          "site_title" => title,
          "ghost_version" => site["version"].presence,
          "key_id" => match[:id].downcase,
          "authority_summary" => "Writes to #{title} (#{site_url}) with an Admin API key: it can create, edit, " \
                                 "publish and delete any post or page there, and send newsletters. Residents " \
                                 "write drafts and publish only when asked."
        }.compact
      }
    end

    def revoke(_connection)
      # The owner regenerates or deletes the key in Ghost (Settings →
      # Integrations); souls.house removes its copy.
      true
    end

    # The address residents call: scheme, host, port and any subdirectory
    # Ghost is installed under, without Ghost's own /ghost/... path.
    def self.normalize_api_url(value)
      raw = value.to_s.strip
      return nil if raw.blank?

      raw = "https://#{raw}" unless raw.match?(%r{\A[a-z][a-z0-9+.-]*://}i)
      uri = URI.parse(raw)
      raise Error, "The Ghost API URL must start with https://" unless uri.scheme&.downcase == "https"
      raise Error, "The Ghost API URL needs a host name" if uri.host.blank?
      raise Error, "The Ghost API URL can't carry a user name or password" if uri.userinfo.present?

      path = uri.path.to_s.sub(%r{/ghost(?:/.*)?\z}i, "").chomp("/")
      port = uri.port == 443 ? "" : ":#{uri.port}"
      "https://#{uri.host.downcase}#{port}#{path}"
    rescue URI::InvalidURIError
      raise Error, "That isn't a valid Ghost API URL"
    end

    # A short-lived Admin API token, as Ghost documents it: HS256 over the
    # key's hex-decoded secret, kid = the key's id, audience /admin/.
    def self.admin_token(key, now: Time.current)
      match = KEY_PATTERN.match(key.to_s.strip) or raise Error, "Invalid Ghost Admin API key"
      header = { alg: "HS256", typ: "JWT", kid: match[:id] }
      payload = { iat: now.to_i, exp: now.to_i + 300, aud: "/admin/" }
      signing_input = [ header, payload ].map { |part| Base64.urlsafe_encode64(part.to_json, padding: false) }.join(".")
      signature = OpenSSL::HMAC.digest("SHA256", [ match[:secret] ].pack("H*"), signing_input)
      "#{signing_input}.#{Base64.urlsafe_encode64(signature, padding: false)}"
    end

    private

    def get_json(api_url, path, key)
      uri = URI("#{api_url}/ghost/api/admin#{path}")
      address = public_address_for(uri.host)

      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Accept-Version"] = ACCEPT_VERSION
      request["Authorization"] = "Ghost #{self.class.admin_token(key)}"
      request["User-Agent"] = "souls.house service connection"

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = true
      http.ipaddr = address
      http.open_timeout = 10
      http.read_timeout = 15
      response = http.start { |connection| connection.request(request) }

      case response
      when Net::HTTPSuccess
        body = JSON.parse(response.body)
        raise Error, "#{uri.host} didn't answer like a Ghost site" unless body.is_a?(Hash)

        body
      when Net::HTTPRedirection
        target = URI(response["location"].to_s).host rescue nil
        raise Error, "#{uri.host} redirects#{" to #{target}" if target.present?}; use the API URL shown in Ghost under " \
                     "Settings → Integrations"
      when Net::HTTPUnauthorized, Net::HTTPForbidden
        raise Error, "#{uri.host} rejected this Admin API key"
      when Net::HTTPNotFound
        raise Error, "#{uri.host} has no Ghost Admin API at #{uri.path.sub(%r{/[^/]*\z}, '/')}; check the API URL"
      else
        raise Error, "Ghost validation failed (#{response.code})"
      end
    rescue JSON::ParserError
      raise Error, "#{uri.host} didn't answer like a Ghost site"
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError
      raise Error, "Could not reach #{uri.host} over https"
    end

    # The first address the host resolves to, refusing hosts that resolve to
    # anything that isn't on the public internet. The request is then pinned
    # to that address, so a second lookup can't send it somewhere else.
    def public_address_for(host)
      addresses = resolve_addresses(host)
      raise Error, "Could not find #{host}" if addresses.empty?
      raise Error, "#{host} is not on the public internet" unless addresses.all? { |address| public_address?(address) }

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
      OpenSSL::HMAC.hexdigest("SHA256", secret, key.downcase)
    end

  end
end
