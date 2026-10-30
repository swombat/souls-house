# Fetches a picture someone pasted as a URL (an avatar, for now) and hands it
# back as bytes ready to attach. The address is the person's, so it is treated
# as hostile: only http(s), every DNS answer must be public (the Ghost policy),
# the connection is pinned to the checked address, each redirect is checked
# again, the body is capped while it streams, and the type comes from the
# bytes, not from what the server says.
class RemoteImageFetch

  class Error < StandardError; end

  Result = Data.define(:io, :filename, :content_type)

  MAX_BYTES = 5.megabytes
  MAX_REDIRECTS = 3
  EXTENSIONS = { "image/png" => "png", "image/jpeg" => "jpg", "image/gif" => "gif", "image/webp" => "webp" }.freeze
  NON_PUBLIC_RANGES = Services::GhostAdapter::NON_PUBLIC_RANGES

  def self.call(url, resolver: nil)
    new(resolver:).call(url)
  end

  # `address_check` is a test seam: only the transport tests, which need a
  # loopback server, replace the public-address rule.
  def initialize(resolver: nil, address_check: nil)
    @resolver = resolver || ->(host) { Resolv.getaddresses(host).uniq }
    @address_check = address_check || method(:public_address?)
  end

  def call(url)
    uri = parse(url)
    (MAX_REDIRECTS + 1).times do
      response, body = get(uri)
      case response
      when Net::HTTPRedirection
        location = response["location"].to_s
        raise Error, "That address redirects without saying where" if location.blank?

        uri = parse(URI.join(uri.to_s, location).to_s)
      when Net::HTTPSuccess
        return result_for(uri, body)
      else
        raise Error, "That address answered HTTP #{response.code}, not a picture"
      end
    end
    raise Error, "That address redirects too many times"
  end

  private

  def parse(url)
    uri = URI.parse(url.to_s.strip)
    raise Error, "Paste a web address starting with http:// or https://" unless uri.is_a?(URI::HTTP) && uri.host.present?

    uri
  rescue URI::InvalidURIError
    raise Error, "That doesn't look like a web address"
  end

  def get(uri)
    http = Net::HTTP.new(uri.hostname, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.ipaddr = public_address_for(uri.hostname)
    http.open_timeout = 5
    http.read_timeout = 10
    http.max_retries = 0

    request = Net::HTTP::Get.new(uri)
    request["Accept"] = "image/*"
    request["User-Agent"] = "avatar-fetch/1.0"

    body = +""
    response = http.start do |connection|
      # Every body is read here and counted, redirects and errors included:
      # a body left unread is buffered whole by Net::HTTP after the block.
      connection.request(request) do |res|
        res.read_body do |chunk|
          body << chunk
          raise Error, "That picture is over 5 MB" if body.bytesize > MAX_BYTES
        end
      end
    end
    [ response, body ]
  rescue SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout, OpenSSL::SSL::SSLError, EOFError
    raise Error, "Couldn't reach that address"
  end

  def public_address_for(host)
    addresses = (IPAddr.new(host) rescue nil) ? [ host ] : @resolver.call(host)
    raise Error, "Couldn't find that address" if addresses.empty?
    raise Error, "That address isn't on the public internet" unless addresses.all? { |a| @address_check.call(a) }

    addresses.first
  end

  def public_address?(address)
    ip = IPAddr.new(address.to_s.delete_prefix("[").delete_suffix("]"))
    ip = ip.native if ip.ipv4_mapped?
    NON_PUBLIC_RANGES.none? { |range| range.family == ip.family && range.include?(ip) }
  rescue IPAddr::Error
    false
  end

  def result_for(uri, body)
    raise Error, "That address returned nothing" if body.empty?

    content_type = Marcel::MimeType.for(StringIO.new(body))
    extension = EXTENSIONS[content_type]
    raise Error, "That address isn't a PNG, JPEG, GIF or WebP picture" unless extension

    base = File.basename(uri.path.to_s).sub(/\.[^.]*\z/, "").gsub(/[^\w-]/, "").presence || "avatar"
    Result.new(io: StringIO.new(body), filename: "#{base.first(60)}.#{extension}", content_type:)
  end

end
