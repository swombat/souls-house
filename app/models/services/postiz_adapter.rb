require "net/http"
require "json"
require "openssl"
require "resolv"
require "ipaddr"
require "date"
require "time"
require "time"

module Services
  # Credentials remain inside the service boundary.
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
    MEDIA_PROVIDERS = %w[facebook instagram instagram-standalone tiktok tiktok-business youtube].freeze

    def connection_attributes(credentials:, user:)
      base = normalize_base(credentials["api_base"])
      token = credentials["api_token"].to_s.strip
      raise Error, "Postiz personal API token is required" if token.blank? || token.match?(/[\r\n]/)
      publishing = credentials["publishing"]
      raise Error, "Publishing must be enabled or disabled" unless publishing.blank? || %w[enabled disabled].include?(publishing)

      channels(base, token)
      {
        external_subject_id: credential_fingerprint("#{base}:#{token}"),
        external_identity: base,
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint("#{base}:#{token}"),
        credential_payload: { "api_token" => token, "api_base" => base },
        credential_metadata: {
          "credential_strategy" => "postiz_proxy",
          "publishing_enabled" => publishing == "enabled",
          "authority_summary" => "House-enforced channel listing, media upload and draft creation#{publishing == 'enabled' ? ', publishing and scheduling' : ' only'}. The underlying Postiz token may have broader authority."
        }
      }
    end

    def list_channels(connection)
      payload = connection.credential_payload_hash
      channels(payload.fetch("api_base"), payload.fetch("api_token"))
    end

    def create_draft(connection, channel_id:, content:)
      create_post(connection, channel_id: channel_id, content: content, mode: "draft")
    end

    # Postiz public DTOs and provider settings at 7fa06d1200c9d9f54754dad04139a18d70906c04:
    # libraries/nestjs-libraries/src/dtos/posts/{create.post.dto.ts,providers-settings/*.dto.ts}
    # and public-api/routes/v1/public.integrations.controller.ts.
    def create_post(connection, channel_id:, content:, mode:, scheduled_at: nil, settings: {}, media: [])
      raise Error, "A channel and text content are required" unless channel_id.is_a?(String) && channel_id.present? &&
        content.is_a?(String) && content.present? && content.bytesize <= 100_000
      raise Error, "Invalid post mode" unless %w[draft publish_now scheduled].include?(mode)
      if mode != "draft" && connection.credential_metadata.to_h["publishing_enabled"] != true
        raise Error, "Publishing is not enabled for this Postiz connection"
      end
      if mode == "scheduled"
        unless scheduled_at.is_a?(String) && scheduled_at.match?(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d(?:\.\d{1,6})?(?:Z|[+-](?:0\d|1[0-4]):[0-5]\d)\z/)
          raise Error, "Schedule must be a timezone-qualified future ISO 8601 date"
        end
        begin
          DateTime.iso8601(scheduled_at) # Reject impossible dates rather than normalizing them.
          date = Time.iso8601(scheduled_at)
        rescue ArgumentError
          raise Error, "Schedule must be a timezone-qualified future ISO 8601 date"
        end
        raise Error, "Schedule must be in the future" unless date > Time.current
      else
        raise Error, "Schedule is only permitted for scheduled posts" unless scheduled_at.nil?
        date = Time.current
      end

      payload = connection.credential_payload_hash
      base, token = payload.values_at("api_base", "api_token")
      channel = channels(base, token).find { |entry| entry["id"] == channel_id }
      raise Error, "Unknown Postiz channel" unless channel
      raise Error, "Postiz channel is disabled" if channel["disabled"] == true
      raise Error, "Postiz channel has no platform identifier" if channel["identifier"].blank?
      provider = channel["identifier"]
      unless (TEXT_DRAFT_PROVIDERS + MEDIA_PROVIDERS).include?(provider)
        raise Error, "This Postiz platform is not supported; create the post in Postiz"
      end
      media = validate_media(connection, media)
      if %w[instagram instagram-standalone tiktok tiktok-business youtube].include?(provider) && media.empty?
        raise Error, "Text-only posts are not supported; media is required for this Postiz platform"
      end
      settings = provider_settings(provider, settings)
      if provider == "facebook" && settings.key?("text_format_preset_id") &&
          (media.any? || content.length > 130 || settings["post_type"] == "story")
        raise Error, "Facebook background presets require a text-only post of at most 130 characters"
      end
      if mode != "draft" && %w[tiktok tiktok-business].include?(provider) && settings["content_posting_method"] != "DIRECT_POST"
        raise Error, "TikTok publishing requires DIRECT_POST; UPLOAD only sends media to the TikTok inbox"
      end
      validate_provider_media(provider, settings, media)

      # Construct the payload from validated, allowlisted fields.
      result = request_json(base, token, "/posts", {
        type: { "draft" => "draft", "publish_now" => "now", "scheduled" => "schedule" }.fetch(mode),
        shortLink: false, date: date.utc.iso8601, tags: [],
        posts: [ { integration: { id: channel_id }, settings: settings,
                   value: [ { content: content, image: media } ] } ]
      })
      # Do not forward provider objects (including nested credentials).
      posts = result.is_a?(Hash) ? [ result ] : result
      unless posts.is_a?(Array) && posts.present? && posts.all? { |post| post.is_a?(Hash) }
        raise Error, "Invalid Postiz post receipt; outcome unknown. Check Postiz before retrying."
      end
      posts.map do |post|
        receipt = post.slice("id", "postId").select { |_key, value| value.is_a?(String) && value.present? }
        raise Error, "Invalid Postiz post receipt; outcome unknown. Check Postiz before retrying." if receipt.empty?

        receipt
      end
    end

    def upload_media(connection, file:)
      Services::PostizMediaUpload.new(self).call(connection, file: file)
    end

    private

    def validate_provider_media(provider, settings, media)
      types = media.map do |item|
        path = URI.parse(item["path"]).path.to_s
        ext = File.extname(path)
        raise Error, "Unsupported media type" unless %w[.jpg .jpeg .png .gif .webp .mp4].include?(ext)
        ext == ".mp4" ? :video : :image
      rescue URI::InvalidURIError
        raise Error, "Invalid media"
      end
      invalid = case provider
      when "youtube" then types != [:video]
      when "tiktok", "tiktok-business" then types.include?(:video) && types != [:video]
      when "facebook"
        (settings["post_type"] == "story" && types.size != 1) ||
          (types.include?(:video) && types != [:video])
      when "instagram", "instagram-standalone"
        (settings["post_type"] == "story" && types.size != 1) ||
          (settings["is_trial_reel"] == true && (types != [:video] || settings["post_type"] != "post"))
      else false
      end
      raise Error, "Unsupported media combination for this Postiz platform" if invalid
    end

    def validate_media(connection, media)
      raise Error, "Invalid media" unless media.is_a?(Array) && media.size <= 10
      media.map do |item|
        raise Error, "Invalid media" unless item.is_a?(Hash) && item.keys.all? { |key| key.is_a?(String) } &&
          item.keys.sort == %w[id path upload_token] &&
          item["id"].is_a?(String) && item["id"].present? && item["path"].is_a?(String) &&
          item["path"].present? && item["path"].bytesize <= 4096 &&
          item["upload_token"].is_a?(String) && item["upload_token"].bytesize <= 16_384 && connection.id.present?
        verified = Rails.application.message_verifier("postiz-media").verified(item["upload_token"], purpose: "postiz-media")
        unless verified == { "connection_id" => connection.id, "id" => item["id"], "path" => item["path"] }
          raise Error, "Invalid media"
        end
        item.slice("id", "path")
      end
    end

    def provider_settings(provider, input)
      raise Error, "Invalid provider settings" unless input.is_a?(Hash) && input.keys.all? { |k| k.is_a?(String) }
      result = { "__type" => provider }
      allowed = case provider
      when "facebook" then %w[post_type title text_format_preset_id]
      when "instagram", "instagram-standalone" then %w[post_type is_trial_reel graduation_strategy]
      when "tiktok", "tiktok-business"
        %w[title privacy_level duet stitch comment autoAddMusic brand_content_toggle brand_organic_toggle video_made_with_ai content_posting_method]
      when "youtube" then %w[title type selfDeclaredMadeForKids]
      when "x" then %w[who_can_reply_post]
      else []
      end
      raise Error, "Unsupported provider settings" unless (input.keys - allowed).empty?
      result.merge!(input)
      result["who_can_reply_post"] ||= "everyone" if provider == "x"
      enums = case provider
      when "facebook" then { "post_type" => %w[post story] }
      when "instagram", "instagram-standalone" then { "post_type" => %w[post story], "graduation_strategy" => %w[MANUAL SS_PERFORMANCE] }
      when "tiktok", "tiktok-business"
        { "privacy_level" => %w[PUBLIC_TO_EVERYONE MUTUAL_FOLLOW_FRIENDS FOLLOWER_OF_CREATOR SELF_ONLY],
          "autoAddMusic" => %w[yes no], "content_posting_method" => %w[DIRECT_POST UPLOAD] }
      when "youtube" then { "type" => %w[public private unlisted], "selfDeclaredMadeForKids" => %w[yes no] }
      when "x" then { "who_can_reply_post" => %w[everyone mentionedUsers following] }
      else {}
      end
      required = case provider
      when "instagram", "instagram-standalone" then %w[post_type]
      when "tiktok", "tiktok-business" then %w[privacy_level duet stitch comment autoAddMusic brand_content_toggle brand_organic_toggle content_posting_method]
      when "youtube" then %w[title type]
      else []
      end
      raise Error, "Missing provider settings" unless required.all? { |key| input.key?(key) }
      enums.each { |key, values| raise Error, "Invalid provider settings" if result.key?(key) && !values.include?(result[key]) }
      %w[duet stitch comment brand_content_toggle brand_organic_toggle video_made_with_ai is_trial_reel].each do |key|
        raise Error, "Invalid provider settings" if result.key?(key) && ![true, false].include?(result[key])
      end
      %w[title text_format_preset_id].each do |key|
        raise Error, "Invalid provider settings" if result.key?(key) && (!result[key].is_a?(String) || result[key].length > (provider == "tiktok" || provider == "tiktok-business" ? 90 : 100))
      end
      raise Error, "Invalid provider settings" if provider == "youtube" && result["title"].empty?
      result
    end

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
          .merge("draft_supported" => (TEXT_DRAFT_PROVIDERS + ["facebook"]).include?(channel["identifier"]),
                 "post_supported" => (TEXT_DRAFT_PROVIDERS + MEDIA_PROVIDERS).include?(channel["identifier"]),
                 "media_required" => %w[instagram instagram-standalone tiktok tiktok-business youtube].include?(channel["identifier"]))
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
      unless response.is_a?(Net::HTTPSuccess)
        raise Error, "Postiz request failed (#{response.code}); redirects are not followed#{body ? '; outcome may be unknown. Check Postiz before retrying.' : ''}"
      end

      JSON.parse(response.body)
    rescue JSON::ParserError
      raise Error, "Invalid Postiz response; post outcome may be unknown. Check Postiz before retrying."
    rescue SocketError, SystemCallError, IOError, Timeout::Error, OpenSSL::SSL::SSLError
      raise Error, "Postiz request failed; post outcome may be unknown. Check Postiz before retrying."
    end
  end
end
