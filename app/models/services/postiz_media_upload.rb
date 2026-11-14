require "net/http"
require "json"
require "openssl"
require "securerandom"
require "tempfile"
require "timeout"

module Services
  class PostizMediaUpload
    MAX_BYTES = 50 * 1024 * 1024
    MAX_IMAGE_BYTES = 10 * 1024 * 1024
    MAX_RECEIPT_BYTES = 64 * 1024
    TYPES = { "image/jpeg" => "jpg", "image/png" => "png",
              "image/webp" => "webp", "video/mp4" => "mp4" }.freeze
    UNKNOWN = "Postiz upload failed; outcome may be unknown. Check Postiz before retrying.".freeze

    def initialize(adapter)
      @adapter = adapter
    end

    # Postiz public.integrations.controller.ts: POST /upload, multipart field
    # "file", adjust defaults to false. Never use /upload-from-url.
    def call(connection, file:)
      type = file.content_type
      fail_upload("Supported media: JPEG, PNG, WebP and MP4") unless TYPES.key?(type)
      limit = type == "video/mp4" ? MAX_BYTES : MAX_IMAGE_BYTES
      fail_upload("Media exceeds its size limit (images 10 MiB, video 50 MiB)") unless file.size.between?(1, limit)
      credentials = connection.credential_payload_hash
      token = credentials["api_token"]
      fail_upload("Invalid Postiz credentials") unless token.is_a?(String) &&
        !token.empty? && !token.match?(/[\x00-\x20\x7f]/)
      uri = URI("#{@adapter.send(:normalize_base, credentials["api_base"])}/upload")
      address = @adapter.send(:public_address_for, uri.hostname)
      boundary = "postiz-#{SecureRandom.hex(24)}"

      Tempfile.create(["postiz-upload", ".multipart"], binmode: true) do |body|
        body.write("--#{boundary}\r\nContent-Disposition: form-data; name=\"file\"; filename=\"#{SecureRandom.hex(16)}.#{TYPES.fetch(type)}\"\r\nContent-Type: #{type}\r\n\r\n")
        file.rewind
        signature = file.read(64).to_s.b
        fail_upload("Media content does not match its type") unless magic?(type, signature)
        body.write(signature)
        size = signature.bytesize
        while (chunk = file.read(64 * 1024))
          break if chunk.empty?
          size += chunk.bytesize
          fail_upload("Media exceeds its size limit (images 10 MiB, video 50 MiB)") if size > limit
          body.write(chunk)
        end
        body.write("\r\n--#{boundary}--\r\n")
        body.rewind
        request = Net::HTTP::Post.new(uri)
        request["Authorization"] = token
        request["Accept"] = "application/json"
        request["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
        request.content_length = body.size
        request.body_stream = body
        receipt = transmit(uri, address, request)
        sanitized = sanitize(receipt)
        sanitized.merge("upload_token" => Rails.application.message_verifier("postiz-media").generate(
          { "connection_id" => connection.id, "id" => sanitized.fetch("id"), "path" => sanitized.fetch("path") },
          purpose: "postiz-media"))
      end
    rescue JSON::ParserError, URI::InvalidURIError, SocketError, SystemCallError,
           IOError, Timeout::Error, OpenSSL::SSL::SSLError, EOFError
      fail_upload(UNKNOWN)
    end

    private

    def fail_upload(message)
      raise Services::PostizAdapter::Error, message
    end

    def magic?(type, bytes)
      case type
      when "image/jpeg" then bytes.start_with?("\xff\xd8\xff".b)
      when "image/png" then bytes.start_with?("\x89PNG\r\n\x1a\n".b)
      when "image/webp"
        bytes.start_with?("RIFF") && bytes.byteslice(8, 4) == "WEBP" &&
          %w[VP8\  VP8L VP8X].include?(bytes.byteslice(12, 4))
      when "video/mp4"
        box_size = bytes.byteslice(0, 4)&.unpack1("N")
        box_size && box_size >= 16 && bytes.byteslice(4, 4) == "ftyp" &&
          %w[isom iso2 iso3 iso4 iso5 iso6 mp41 mp42 avc1 M4V\  dash].include?(bytes.byteslice(8, 4))
      else false
      end
    end

    def transmit(uri, address, request)
      http = Net::HTTP.new(uri.hostname, uri.port, nil) # No environment proxy.
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.ipaddr = address # Retain hostname for TLS verification and SNI.
      http.open_timeout = 10
      http.read_timeout = 20
      http.write_timeout = 20
      http.max_retries = 0
      bytes = +""
      Timeout.timeout(90) do
        http.start do |client|
          client.request(request) do |response|
            fail_upload(UNKNOWN) unless response.is_a?(Net::HTTPSuccess)
            response.read_body do |chunk|
              fail_upload(UNKNOWN) if bytes.bytesize + chunk.bytesize > MAX_RECEIPT_BYTES
              bytes << chunk
            end
          end
        end
      end
      JSON.parse(bytes)
    end

    def sanitize(receipt)
      fail_upload(UNKNOWN) unless receipt.is_a?(Hash)
      id, path = receipt.values_at("id", "path")
      fail_upload(UNKNOWN) unless id.is_a?(String) && id.match?(/\A[a-zA-Z0-9_-]{1,200}\z/) &&
        path.is_a?(String) && path.bytesize.between?(1, 4096) && !path.match?(/[\x00-\x20\x7f\\]/)
      uri = URI.parse(path)
      fail_upload(UNKNOWN) unless uri.scheme == "https" && uri.hostname &&
        uri.userinfo.nil? && uri.fragment.nil? && uri.query.nil? &&
        uri.port == 443 && uri.path.start_with?("/") && uri.path != "/" &&
        !uri.path.match?(/%|(?:\A|\/)\.\.?(?:\/|\z)/)
      # Validate all DNS answers, but do not fetch media or follow redirects.
      @adapter.send(:public_address_for, uri.hostname)
      { "id" => id, "path" => path }
    rescue Services::PostizAdapter::Error, URI::InvalidURIError
      fail_upload(UNKNOWN)
    end
  end
end
