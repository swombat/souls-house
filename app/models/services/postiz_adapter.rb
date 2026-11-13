require "net/http"
require "json"
require "openssl"
require "resolv"
require "ipaddr"

module Services
  # The token never leaves Rails. Only these two operations are implemented.
  class PostizAdapter
    class Error < Services::AdapterError; end

    NON_PUBLIC_RANGES = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.168.0.0/16 198.18.0.0/15 224.0.0.0/3
      ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8
    ].map { |range| IPAddr.new(range) }.freeze

    def initialize(definition)
      @definition = definition
    end

    def revoke(_connection)
      true
    end
    DEFAULT_BASE = "https://api.postiz.com/public/v1".freeze
    CHANNEL_FIELDS = %w[id name identifier picture disabled].freeze
    # Verified against Postiz 23f29c458ab3cd79d785c1c45ed9c9888d5005bf:
    # all.providers.settings.ts, linkedin.dto.ts and x.dto.ts. Public drafts
    # still undergo provider settings validation before being stored.
    TEXT_DRAFT_PROVIDERS = %w[x linkedin linkedin-page threads mastodon bluesky telegram nostr vk].freeze

    def connection_attributes(credentials:, user:)
      base = normalize_base(credentials["api_base"])
      token = credentials["api_token"].to_s.strip
      raise Error, "Postiz personal API token is required" if token.blank? || token.match?(/[\r\n]/)

      channels(base, token)
      {
        external_subject_id: credential_fingerprint("#{base}:#{token}"),
        external_identity: base,
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint("#{base}:#{token}"),
        credential_payload: { "api_token" => token, "api_base" => base },
        credential_metadata: {
          "credential_strategy" => "postiz_proxy",
          "authority_summary" => "House-enforced channel listing and draft creation only. The underlying Postiz token may have broader authority."
        }
      }
    end

    def list_channels(connection)
      payload = connection.credential_payload_hash
      channels(payload.fetch("api_base"), payload.fetch("api_token"))
    end

    def create_draft(connection, channel_id:, content:)
      raise Error, "A channel and text content are required" unless channel_id.is_a?(String) && channel_id.present? &&
        content.is_a?(String) && content.present? && content.bytesize <= 100_000

      payload = connection.credential_payload_hash
      base, token = payload.values_at("api_base", "api_token")
      channel = channels(base, token).find { |entry| entry["id"] == channel_id }
      raise Error, "Unknown Postiz channel" unless channel
      raise Error, "Postiz channel has no platform identifier" if channel["identifier"].blank?
      unless TEXT_DRAFT_PROVIDERS.include?(channel["identifier"])
        raise Error, "Text drafts for this Postiz platform are not supported; create the draft in Postiz"
      end
      settings = { __type: channel["identifier"] }
      settings[:who_can_reply_post] = "everyone" if channel["identifier"] == "x"

      # Construct, never forward, the payload: no date, media, publish or settings
      # supplied by a resident can cross this boundary.
      result = request_json(base, token, "/posts", {
        type: "draft", shortLink: false, date: Time.current.utc.iso8601, tags: [],
        posts: [ { integration: { id: channel_id }, settings: settings,
                   value: [ { content: content, image: [] } ] } ]
      })
      # Do not forward provider objects (including nested credentials).
      posts = result.is_a?(Hash) ? [ result ] : result
      unless posts.is_a?(Array) && posts.present? && posts.all? { |post| post.is_a?(Hash) }
        raise Error, "Invalid Postiz draft receipt; outcome unknown. Check Postiz before retrying."
      end
      posts.map do |post|
        receipt = post.slice("id", "postId").select { |_key, value| value.is_a?(String) && value.present? }
        raise Error, "Invalid Postiz draft receipt; outcome unknown. Check Postiz before retrying." if receipt.empty?

        receipt
      end
    end

    private

    def credential_fingerprint(value)
      secret = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", secret, value)
    end

    def public_address?(address)
      ip = IPAddr.new(address.to_s.delete_prefix("[").delete_suffix("]"))
      ip = ip.native if ip.ipv4_mapped?
      return false if NON_PUBLIC_RANGES.any? { |range| range.family == ip.family && range.include?(ip) }

      extra = %w[192.0.2.0/24 198.51.100.0/24 203.0.113.0/24 2001:db8::/32 2001::/32 2002::/16]
      return false if extra.any? { |range| IPAddr.new(range).include?(ip) }

      ip.ipv4? || IPAddr.new("2000::/3").include?(ip)
    rescue IPAddr::Error
      false
    end

    def resolve_addresses(host)
      return [ host ] if (IPAddr.new(host) rescue nil)

      Resolv.getaddresses(host).uniq
    end

    def public_address_for(host)
      addresses = resolve_addresses(host)
      raise Error, "Postiz host must resolve only to public internet addresses" if addresses.empty? ||
        !addresses.all? { |address| public_address?(address) }

      addresses.first
    end

    def normalize_base(value)
      uri = URI.parse(value.presence || DEFAULT_BASE)
      unless uri.scheme == "https" && uri.host.present? && uri.userinfo.nil? &&
          uri.query.nil? && uri.fragment.nil? && !uri.path.match?(/%|\\|\.\./)
        raise Error, "Postiz API base must be a public HTTPS URL without credentials, query or fragment"
      end
      uri.to_s.chomp("/")
    rescue URI::InvalidURIError
      raise Error, "Invalid Postiz API base"
    end

    def channels(base, token)
      result = request_json(base, token, "/integrations")
      raise Error, "Invalid Postiz channels response" unless result.is_a?(Array)

      # GHSA-jhfm-m4vp-jcpc: never return raw integration objects.
      result.filter_map do |channel|
        next unless channel.is_a?(Hash)
        channel.slice(*CHANNEL_FIELDS).select { |_key, value| value.is_a?(String) || value == true || value == false }
          .merge("draft_supported" => TEXT_DRAFT_PROVIDERS.include?(channel["identifier"]))
      end
    end

    def request_json(base, token, path, body = nil)
      uri = URI("#{normalize_base(base)}#{path}")
      address = public_address_for(uri.hostname)
      request = body ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["Authorization"] = token
      request["Accept"] = "application/json"
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      http = Net::HTTP.new(uri.hostname, uri.port, nil)
      http.use_ssl = true
      http.ipaddr = address
      http.open_timeout = 10
      http.read_timeout = 20
      http.write_timeout = 20
      http.max_retries = 0
      response = http.start { |client| client.request(request) }
      raise Error, "Postiz request failed (#{response.code}); redirects are not followed" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "Invalid Postiz response; draft outcome may be unknown. Check Postiz before retrying."
    rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, "Postiz request failed; draft outcome may be unknown. Check Postiz before retrying."
    end
  end
end
