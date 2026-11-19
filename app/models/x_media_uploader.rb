require "net/http"
require "json"

# Uploads one image or video to X for a post (XPoster), and returns X's
# media id once the media can be attached. Checked against X's docs on
# 19 Nov 2026 (docs.x.com/x-api/media/quickstart/media-upload-chunked):
#
#   video: POST /2/media/upload/initialize (JSON: media_type, total_bytes,
#          media_category tweet_video), POST /2/media/upload/{id}/append
#          (multipart: segment_index, media; at most 5 MB a segment),
#          POST /2/media/upload/{id}/finalize, then while processing_info is
#          pending or in_progress, GET /2/media/upload?command=STATUS&media_id=
#          after check_after_secs, until succeeded or failed.
#   image: POST /2/media/upload (multipart: media, media_category
#          tweet_image or tweet_gif; up to 5 MB).
#
# All of it needs the media.write scope. An upload never publishes anything,
# so every failure here is NotSent: the post is a plain failure, not an
# unknown one. Only media X reports as ready is ever returned.
class XMediaUploader

  API_BASE = "https://api.x.com/2"

  class NotSent < StandardError

    attr_reader :reason

    def initialize(reason, message)
      @reason = reason
      super(message)
    end

  end

  CONNECT_ERRORS = [ Net::OpenTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError ].freeze
  IN_FLIGHT_ERRORS = [ Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError ].freeze

  SEGMENT_BYTES = 4.megabytes
  PROCESSING_LIMIT = 15.minutes
  MIN_WAIT = 1
  MAX_WAIT = 30
  MEDIA_ID_PATTERN = /\A\d{1,25}\z/

  # How the uploader waits between processing checks; tests replace it.
  class_attribute :sleeper, instance_accessor: false, default: ->(seconds) { sleep(seconds) }

  def initialize(access_token:, on_progress: nil, sleeper: self.class.sleeper, clock: -> { Time.current })
    @access_token = access_token
    @on_progress = on_progress || -> { }
    @sleeper = sleeper
    @clock = clock
  end

  def upload_image(io, content_type:)
    category = content_type == "image/gif" ? "tweet_gif" : "tweet_image"
    body, type = multipart([ [ "media_category", category ], [ "media", io.read, content_type ] ])
    data = call(:post, "/media/upload", body, content_type: type, label: "image upload")
    media_id = media_id_from(data, "image upload")
    wait_until_ready(media_id, data)
  end

  def upload_video(io, size:, content_type: "video/mp4")
    init = call(:post, "/media/upload/initialize",
                { media_type: content_type, total_bytes: size, media_category: "tweet_video" }.to_json,
                label: "video upload setup")
    media_id = media_id_from(init, "video upload setup")

    index = 0
    sent = 0
    while (chunk = io.read(SEGMENT_BYTES)) && !chunk.empty?
      body, type = multipart([ [ "segment_index", index.to_s ], [ "media", chunk, "application/octet-stream" ] ])
      call(:post, "/media/upload/#{media_id}/append", body, content_type: type, label: "video upload", allow_empty: true)
      sent += chunk.bytesize
      index += 1
      on_progress.call
    end
    raise NotSent.new("media_failed", "The video file was #{sent} bytes, not the #{size} expected; nothing was posted") unless sent == size

    finalized = call(:post, "/media/upload/#{media_id}/finalize", nil, label: "video upload finish")
    wait_until_ready(media_id, finalized)
  end

  private

  attr_reader :access_token, :on_progress, :sleeper, :clock

  def media_id_from(data, label)
    payload = data["data"].is_a?(Hash) ? data["data"] : {}
    media_id = payload["id"].to_s
    raise NotSent.new("media_failed", "X's #{label} answer had no media id") unless media_id.match?(MEDIA_ID_PATTERN)

    media_id
  end

  # No processing_info means ready. Otherwise only "succeeded" is ready;
  # "failed" or no answer by the deadline means nothing is posted.
  def wait_until_ready(media_id, data)
    deadline = clock.call + PROCESSING_LIMIT
    polled = false
    loop do
      payload = data["data"].is_a?(Hash) ? data["data"] : {}
      info = payload["processing_info"]
      unless info.is_a?(Hash)
        # Before polling, no processing_info means X needs no processing. Once
        # X has said it is processing, only an explicit "succeeded" is ready.
        return media_id unless polled

        raise NotSent.new("media_failed", "X's processing status answer had no processing state; nothing was posted")
      end

      case info["state"]
      when "succeeded"
        return media_id
      when "failed"
        error = info["error"].is_a?(Hash) ? (info["error"]["message"] || info["error"]["name"]) : nil
        raise NotSent.new("media_failed", "X could not process the media: #{error || 'no reason given'}".truncate(300))
      when "pending", "in_progress"
        nil
      else
        raise NotSent.new("media_failed", "X reported an unreadable processing state (#{info['state'].inspect}); nothing was posted")
      end
      if clock.call > deadline
        raise NotSent.new("media_failed", "X had not finished processing the media after #{PROCESSING_LIMIT.inspect}; nothing was posted")
      end

      on_progress.call
      sleeper.call(info["check_after_secs"].to_i.clamp(MIN_WAIT, MAX_WAIT))
      data = call(:get, "/media/upload?command=STATUS&media_id=#{media_id}", nil, label: "media status check")
      polled = true
    end
  end

  def call(method, path, body, label:, content_type: "application/json", allow_empty: false)
    response = begin
      perform(method, URI("#{API_BASE}#{path}"), body, content_type:)
    rescue *IN_FLIGHT_ERRORS => e
      raise NotSent.new("media_failed", "X could not be reached during the #{label} (#{e.class.name.demodulize})")
    end

    code = response.code.to_i
    unless code.between?(200, 299)
      reason = { 401 => "unauthorized", 403 => "media_forbidden", 429 => "rate_limited" }.fetch(code, "media_failed")
      hint = code == 403 ? " The connection may lack the media.write permission; the owner reconnects X." : ""
      raise NotSent.new(reason, "X refused the #{label} (#{code}).#{hint} #{error_detail(response)}".squish)
    end

    data = parse(response.body)
    raise NotSent.new("media_failed", "X's #{label} answer was unreadable") if data.empty? && !allow_empty

    data
  end

  def perform(method, uri, body, content_type:)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 60
    http.write_timeout = 120
    http.max_retries = 0
    begin
      http.start
    rescue *CONNECT_ERRORS => e
      raise NotSent.new("unreachable", "X could not be reached (#{e.class.name.demodulize})")
    end

    request = (method == :get ? Net::HTTP::Get : Net::HTTP::Post).new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    if body
      request["Content-Type"] = content_type
      request.body = body
    end
    http.request(request)
  ensure
    http.finish if http&.started?
  end

  # fields: [name, value] or [name, bytes, content_type] for a file part.
  def multipart(fields)
    boundary = "soulshouse-#{SecureRandom.hex(16)}"
    body = +""
    body.force_encoding(Encoding::BINARY)
    fields.each do |name, value, type|
      body << "--#{boundary}\r\n"
      if type
        body << "Content-Disposition: form-data; name=\"#{name}\"; filename=\"#{name}\"\r\n"
        body << "Content-Type: #{type}\r\n\r\n"
      else
        body << "Content-Disposition: form-data; name=\"#{name}\"\r\n\r\n"
      end
      body << value.to_s.b << "\r\n"
    end
    body << "--#{boundary}--\r\n"
    [ body, "multipart/form-data; boundary=#{boundary}" ]
  end

  def parse(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def error_detail(response)
    data = parse(response.body)
    errors = data["errors"].is_a?(Array) ? data["errors"] : []
    messages = errors.map { |error| error.is_a?(Hash) ? (error["message"] || error["detail"]) : nil }
    [ data["title"], data["detail"], *messages ].select { |part| part.is_a?(String) }.uniq.join(": ").truncate(300)
  end

end
