require "net/http"
require "resolv"
require "ipaddr"

module Visits
  # Outbound HTTP client for the home half of cross-house visits.
  #
  # Security invariants:
  # - Only http(s); https required in production unless explicitly opted into
  #   local/private testing via SOULSHOUSE_ALLOW_PRIVATE_VISIT_ORIGINS=1.
  # - Every DNS answer must be a public IP (same policy as RemoteImageFetch),
  #   and the TCP connection is pinned to the checked address via http.ipaddr.
  # - Redirects (3xx) are always refused so a Bearer visit_token can never be
  #   forwarded to another host or private address.
  # - Response bodies are streamed with a hard byte cap.
  class Client

    class Error < StandardError; end
    class RedirectRefused < Error; end
    class UnsafeOrigin < Error; end
    class NetworkError < Error; end
    class ResponseTooLarge < Error; end
    class InvalidSegment < Error; end

    Response = Data.define(:status, :body, :json, :content_type, :content_disposition) do
      def success?
        (200..299).cover?(status)
      end
    end

    MAX_JSON_BYTES = 2.megabytes
    MAX_ATTACHMENT_BYTES = 10.megabytes
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 15
    NON_PUBLIC_RANGES = Services::GhostAdapter::NON_PUBLIC_RANGES
    SAFE_SEGMENT = /\A[A-Za-z0-9_-]{1,256}\z/

    def self.allow_private_origins?
      ENV["SOULSHOUSE_ALLOW_PRIVATE_VISIT_ORIGINS"] == "1" || Rails.env.development?
    end

    def initialize(resolver: nil, address_check: nil, allow_http: nil)
      @resolver = resolver || ->(host) { Resolv.getaddresses(host).uniq }
      @address_check = address_check || (self.class.allow_private_origins? ? ->(_) { true } : method(:public_address?))
      @allow_http = allow_http.nil? ? self.class.allow_private_origins? : allow_http
    end

    def preview_invitation(origin:, token:)
      request(:get, origin, "/api/v1/visit/invitations/#{safe_segment!(token, 'token')}")
    end

    def accept_invitation(origin:, token:, name:, colour:, icon:, home_origin:, home_name: nil)
      request(
        :post,
        origin,
        "/api/v1/visit/invitations/#{safe_segment!(token, 'token')}/accept",
        payload: {
          name: name,
          colour: colour,
          icon: icon,
          home_origin: home_origin,
          home_name: home_name
        }.compact
      )
    end

    def status(visit)
      request(:get, visit.visited_origin, "/api/v1/visit", token: visit.visit_token)
    end

    def leave(visit)
      request(:delete, visit.visited_origin, "/api/v1/visit", token: visit.visit_token)
    end

    def claim_wakes(visit)
      request(:get, visit.visited_origin, "/api/v1/visit/wakes", token: visit.visit_token)
    end

    def conversation(visit, conversation_id:, wake_id: nil)
      path = "/api/v1/visit/conversations/#{safe_segment!(conversation_id, 'conversation_id')}"
      path = "#{path}?wake_id=#{ERB::Util.url_encode(safe_segment!(wake_id, 'wake_id'))}" if wake_id.present?
      request(:get, visit.visited_origin, path, token: visit.visit_token)
    end

    def post_message(visit, conversation_id:, content:, wake_id: nil)
      payload = { content: content }
      payload[:wake_id] = safe_segment!(wake_id, "wake_id") if wake_id.present?
      request(
        :post,
        visit.visited_origin,
        "/api/v1/visit/conversations/#{safe_segment!(conversation_id, 'conversation_id')}/messages",
        token: visit.visit_token,
        payload: payload
      )
    end

    def attachment(visit, conversation_id:, attachment_id:)
      path = "/api/v1/visit/conversations/#{safe_segment!(conversation_id, 'conversation_id')}/attachments/#{safe_segment!(attachment_id, 'attachment_id')}"
      request(
        :get,
        visit.visited_origin,
        path,
        token: visit.visit_token,
        max_bytes: MAX_ATTACHMENT_BYTES,
        parse_json: false
      )
    end

    def quiet_reason(visit, conversation_id:, reason:, wake_id: nil)
      payload = { reason: reason }
      payload[:wake_id] = safe_segment!(wake_id, "wake_id") if wake_id.present?
      request(
        :post,
        visit.visited_origin,
        "/api/v1/visit/conversations/#{safe_segment!(conversation_id, 'conversation_id')}/quiet_reason",
        token: visit.visit_token,
        payload: payload
      )
    end

    def complete_wake(visit, wake_id:, status: nil)
      payload = status.present? ? { status: status } : {}
      request(
        :post,
        visit.visited_origin,
        "/api/v1/visit/wakes/#{safe_segment!(wake_id, 'wake_id')}/complete",
        token: visit.visit_token,
        payload: payload
      )
    end

    private

    def request(method, origin, path, token: nil, payload: nil, max_bytes: MAX_JSON_BYTES, parse_json: true)
      uri = build_uri(origin, path)
      pinned_ip = resolve_and_check_host!(uri.hostname)

      http = Net::HTTP.new(uri.hostname, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.ipaddr = pinned_ip
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.max_retries = 0

      req_class = { get: Net::HTTP::Get, post: Net::HTTP::Post, delete: Net::HTTP::Delete }.fetch(method)
      http_request = req_class.new(uri)
      http_request["Accept"] = parse_json ? "application/json" : "*/*"
      http_request["User-Agent"] = "souls-house-visit/1.0"
      http_request["Authorization"] = "Bearer #{token}" if token.present?
      if payload
        http_request["Content-Type"] = "application/json"
        http_request.body = payload.to_json
      end

      body = +""
      response = http.start do |connection|
        connection.request(http_request) do |res|
          raise RedirectRefused, "Visited house redirected the request; redirects are refused" if res.is_a?(Net::HTTPRedirection)

          res.read_body do |chunk|
            body << chunk
            raise ResponseTooLarge, "Visited house response exceeded #{max_bytes} bytes" if body.bytesize > max_bytes
          end
        end
      end

      parsed = parse_json ? parse_json_body(body) : nil
      Response.new(
        status: response.code.to_i,
        body: body,
        json: parsed,
        content_type: response["content-type"],
        content_disposition: response["content-disposition"]
      )
    rescue RedirectRefused, UnsafeOrigin, ResponseTooLarge, InvalidSegment
      raise
    rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, EOFError, IOError, Net::HTTPBadResponse => e
      raise NetworkError, "Couldn't reach visited house: #{e.message}"
    end

    def build_uri(origin, path)
      base = URI.parse(origin.to_s.strip)
      unless base.is_a?(URI::HTTP) && base.host.present? && base.userinfo.blank?
        raise UnsafeOrigin, "Visited origin must be a valid http(s) URL"
      end
      if base.scheme == "http" && !@allow_http
        raise UnsafeOrigin, "Visited origin must use https://"
      end

      URI.join("#{base.scheme}://#{base.host.include?(':') ? "[#{base.host}]" : base.host}:#{base.port}", path)
    rescue URI::InvalidURIError
      raise UnsafeOrigin, "Visited origin is not a valid URL"
    end

    def resolve_and_check_host!(host)
      addresses = (IPAddr.new(host) rescue nil) ? [ host ] : @resolver.call(host)
      raise UnsafeOrigin, "Couldn't resolve visited house address" if addresses.empty?
      raise UnsafeOrigin, "Visited house address isn't on the public internet" unless addresses.all? { |addr| @address_check.call(addr) }

      addresses.first
    end

    def public_address?(address)
      ip = IPAddr.new(address.to_s.delete_prefix("[").delete_suffix("]"))
      ip = ip.native if ip.ipv4_mapped?
      NON_PUBLIC_RANGES.none? { |range| range.family == ip.family && range.include?(ip) }
    rescue IPAddr::Error
      false
    end

    def safe_segment!(value, name)
      str = value.to_s
      raise InvalidSegment, "Invalid #{name}" unless str.match?(SAFE_SEGMENT) && str != "." && str != ".."

      str
    end

    def parse_json_body(body)
      return nil if body.blank?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

  end
end
