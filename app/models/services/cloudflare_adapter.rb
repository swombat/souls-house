require "net/http"
require "json"
require "openssl"

module Services
  # A Cloudflare API token, sent as a bearer token. A user token proves itself
  # on /user/tokens/verify; an account-owned token is not a user token, so when
  # that refuses it the token still counts if it can list zones. The zones it
  # can see make the label. Cloudflare decides what the token may do; the
  # house only records which zones it saw.
  class CloudflareAdapter

    API_BASE = "https://api.cloudflare.com/client/v4".freeze
    LABEL_ZONES = 3
    ZONE_PAGES = 20

    class Error < Services::AdapterError; end
    class Rejected < Error; end

    attr_reader :definition

    def initialize(definition)
      @definition = definition
    end

    def connection_attributes(credentials:, user:)
      token = credentials["api_token"].to_s.strip.delete_prefix("Bearer ").strip
      raise Error, "Cloudflare API token is required" if token.blank?

      verified = verify(token)
      zones, zones_complete = list_zones(token, required: verified.nil?)
      accounts = zones.filter_map { |zone| zone.dig("account", "name").presence }.uniq.sort
      names = zones.filter_map { |zone| zone["name"].presence }.sort

      {
        external_subject_id: verified&.dig("id").presence,
        external_identity: accounts.join(", ").presence,
        label: label_for(accounts, names, zones_complete),
        credential_kind: "token",
        credential_fingerprint: credential_fingerprint(token),
        credential_payload: {
          "api_token" => token
        },
        credential_metadata: {
          "credential_strategy" => definition.credential_strategy,
          "token_kind" => verified ? "user" : "account",
          "token_expires_on" => verified&.dig("expires_on").presence,
          "zones" => names,
          "zones_complete" => zones_complete,
          "zone_ids" => zones.to_h { |zone| [ zone["name"], zone["id"] ] }.compact,
          "accounts" => accounts,
          "api_base" => API_BASE,
          "authority_summary" => "Acts with this token's Cloudflare permissions on #{zone_phrase(names)}. " \
                                 "Cloudflare decides what it may change, so give it only the permissions residents need."
        }.compact
      }
    end

    def revoke(_connection)
      # The owner rolls or deletes the token in the Cloudflare dashboard;
      # souls.house removes its copy.
      true
    end

    private

    # The token's own record, or nil when Cloudflare says it isn't a valid
    # user token (account-owned tokens get that answer too).
    def verify(token)
      result = get_json("/user/tokens/verify", token).fetch("result", {})
      status = result["status"].to_s
      raise Error, "This Cloudflare token is #{status}, not active" if status.present? && status != "active"

      result
    rescue Rejected
      nil
    end

    # Every zone the token can see, up to ZONE_PAGES pages of 50; the second
    # value says whether that was all of them.
    def list_zones(token, required:)
      zones = []
      page = 1
      total_pages = 1
      loop do
        body = get_json("/zones?per_page=50&page=#{page}", token)
        zones.concat(Array(body["result"]))
        total_pages = body.dig("result_info", "total_pages").to_i
        break if page >= total_pages || page >= ZONE_PAGES

        page += 1
      end
      raise Error, "This Cloudflare token can't see any zones. Give it Zone → Zone → Read on the zones residents should manage" if required && zones.empty?

      [ zones, page >= total_pages ]
    rescue Rejected
      raise Error, "Cloudflare rejected this API token" if required

      [ [], true ]
    end

    def label_for(accounts, names, complete)
      name = accounts.size == 1 ? "Cloudflare (#{accounts.first})" : "Cloudflare"
      return "#{name}: no zones visible" if names.empty?

      shown = names.first(LABEL_ZONES).join(", ")
      more = names.size - LABEL_ZONES
      tail = if !complete then " and more than #{[ more, 0 ].max} others"
      elsif more.positive? then " and #{more} more"
      else ""
      end
      "#{name}: #{shown}#{tail}"
    end

    def zone_phrase(names)
      case names.size
      when 0 then "the zones it is allowed to reach"
      when 1 then names.first
      else "#{names.size} zones"
      end
    end

    def get_json(path, token)
      uri = URI("#{API_BASE}#{path}")
      request = Net::HTTP::Get.new(uri)
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}"
      request["User-Agent"] = "souls.house service connection"
      response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 15) do |http|
        http.request(request)
      end

      case response
      when Net::HTTPSuccess
        body = JSON.parse(response.body)
        raise Error, "Cloudflare returned an unexpected answer" unless body.is_a?(Hash) && body["success"] != false

        body
      when Net::HTTPUnauthorized, Net::HTTPForbidden, Net::HTTPBadRequest
        raise Rejected, "Cloudflare rejected this API token"
      else
        raise Error, "Cloudflare validation failed (#{response.code})"
      end
    rescue JSON::ParserError
      raise Error, "Cloudflare returned invalid JSON"
    rescue SocketError, Errno::ECONNREFUSED, Net::OpenTimeout, Net::ReadTimeout
      raise Error, "Could not reach api.cloudflare.com"
    end

    def credential_fingerprint(token)
      key = Rails.application.key_generator.generate_key("service-credential-fingerprint", 32)
      OpenSSL::HMAC.hexdigest("SHA256", key, token)
    end

  end
end
