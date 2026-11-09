require "net/http"
require "json"

# The LinkedIn REST calls a post needs: upload an image or a video, then
# create the post. Versioned API (https://api.linkedin.com/rest/), checked
# against LinkedIn's docs on 9 Nov 2026: Linkedin-Version 202610 (versions
# are supported for at least a year), X-Restli-Protocol-Version 2.0.0, the
# new post's URN in the x-restli-id header of a 201.
#
# Every method either returns what it was asked for or raises one of:
#   NotSent       - LinkedIn cannot have published anything (refused, or
#                   unreachable before the request went out);
#   OutcomeUnknown - the create-post request may have been published.
# Media uploads never publish anything, so their failures are all NotSent.
class LinkedinPublisher

  API_BASE = "https://api.linkedin.com/rest"
  VERSION = "202610"

  class NotSent < StandardError

    attr_reader :reason

    def initialize(reason, message)
      @reason = reason
      super(message)
    end

  end

  class OutcomeUnknown < StandardError; end

  CONNECT_ERRORS = [ Net::OpenTimeout, SocketError, SystemCallError, OpenSSL::SSL::SSLError ].freeze
  IN_FLIGHT_ERRORS = [ Net::ReadTimeout, Net::WriteTimeout, EOFError, IOError, SystemCallError, OpenSSL::SSL::SSLError ].freeze

  VIDEO_POLL_INTERVAL = 5
  VIDEO_POLL_LIMIT = 15.minutes

  def initialize(access_token:, author_urn:, on_progress: nil, sleeper: ->(seconds) { sleep(seconds) })
    @access_token = access_token
    @author_urn = author_urn
    @on_progress = on_progress || -> { }
    @sleeper = sleeper
  end

  # Commentary is LinkedIn "little text": these characters are markup and
  # must be escaped to appear as written, or LinkedIn may cut the post short.
  RESERVED = /([\\|{}@\[\]()<>#*_~])/

  def self.escape(text)
    text.to_s.gsub(RESERVED) { "\\#{::Regexp.last_match(1)}" }
  end

  def upload_image(io, content_type:)
    data = rest_json(:post, "/images?action=initializeUpload", { initializeUploadRequest: { owner: author_urn } }, label: "image upload setup")
    value = data["value"].is_a?(Hash) ? data["value"] : {}
    upload_url = value["uploadUrl"]
    image_urn = value["image"]
    raise NotSent.new("media_failed", "LinkedIn's image upload setup gave no upload URL") unless upload_url.is_a?(String) && image_urn.is_a?(String)

    put_bytes(upload_url, io.read, content_type:, label: "image upload")
    image_urn
  end

  def upload_video(io, size:)
    request = { initializeUploadRequest: { owner: author_urn, fileSizeBytes: size, uploadCaptions: false, uploadThumbnail: false } }
    data = rest_json(:post, "/videos?action=initializeUpload", request, label: "video upload setup")
    value = data["value"].is_a?(Hash) ? data["value"] : {}
    video_urn = value["video"]
    instructions = value["uploadInstructions"]
    unless video_urn.is_a?(String) && instructions.is_a?(Array) && instructions.any?
      raise NotSent.new("media_failed", "LinkedIn's video upload setup gave no upload instructions")
    end

    part_ids = instructions.map do |part|
      first = Integer(part["firstByte"])
      last = Integer(part["lastByte"])
      io.seek(first)
      bytes = io.read(last - first + 1).to_s
      raise NotSent.new("media_failed", "The video file is shorter than LinkedIn expected") unless bytes.bytesize == last - first + 1

      response = put_bytes(part["uploadUrl"], bytes, content_type: "application/octet-stream", label: "video upload")
      etag = response["etag"].to_s.delete('"')
      raise NotSent.new("media_failed", "LinkedIn accepted a video part without an ETag") if etag.blank?

      on_progress.call
      etag
    rescue ArgumentError, TypeError
      raise NotSent.new("media_failed", "LinkedIn's video upload instructions were unreadable")
    end

    finalize = { finalizeUploadRequest: { video: video_urn, uploadToken: value["uploadToken"].to_s, uploadedPartIds: part_ids } }
    rest_json(:post, "/videos?action=finalizeUpload", finalize, label: "video upload finish", allow_empty: true)
    wait_until_available(video_urn)
    video_urn
  end

  # Returns the new post's URN. Raises OutcomeUnknown when LinkedIn may have
  # published it but did not say so.
  def create_post(text:, media_urn: nil, media_title: nil)
    body = {
      author: author_urn,
      commentary: self.class.escape(text),
      visibility: "PUBLIC",
      distribution: { feedDistribution: "MAIN_FEED", targetEntities: [], thirdPartyDistributionChannels: [] },
      lifecycleState: "PUBLISHED",
      isReshareDisabledByAuthor: false
    }
    if media_urn
      media = { id: media_urn }
      media[:title] = media_title if media_title.present?
      body[:content] = { media: media }
    end

    response = begin
      perform(:post, URI("#{API_BASE}/posts"), body.to_json)
    rescue *IN_FLIGHT_ERRORS => e
      raise OutcomeUnknown, "#{e.class}: #{e.message}".truncate(300)
    end

    code = response.code.to_i
    detail = error_detail(response)
    case code
    when 200..299
      urn = response["x-restli-id"].to_s
      raise OutcomeUnknown, "LinkedIn answered #{code} without a readable post id" unless urn.match?(LinkedinPost::POST_URN_PATTERN)

      urn
    when 401 then raise NotSent.new("unauthorized", "LinkedIn rejected the sign-in; the owner reconnects LinkedIn from Integrations. #{detail}".strip)
    when 403 then raise NotSent.new("forbidden", "LinkedIn refused the post (the w_member_social permission is missing). #{detail}".strip)
    when 429 then raise NotSent.new("rate_limited", "LinkedIn's posting limit was reached; try later. #{detail}".strip)
    when 400..499 then raise NotSent.new("rejected", "LinkedIn rejected the post (#{code}). #{detail}".strip)
    else raise OutcomeUnknown, "LinkedIn answered #{code}. #{detail}".strip
    end
  end

  private

  attr_reader :access_token, :author_urn, :on_progress, :sleeper

  def wait_until_available(video_urn)
    deadline = VIDEO_POLL_LIMIT.from_now
    loop do
      response = perform(:get, URI("#{API_BASE}/videos/#{ERB::Util.url_encode(video_urn)}"))
      code = response.code.to_i
      # Only AVAILABLE means ready. A 404 just after finalize may be LinkedIn
      # not having the record yet, so it is waited on like PROCESSING (and
      # fails at the deadline); a 403 or anything else stops: nothing is
      # posted on a video whose state the house cannot see.
      if code == 403
        raise NotSent.new("media_failed", "LinkedIn would not show the video's processing status (403), so nothing was posted")
      elsif code != 404 && !code.between?(200, 299)
        raise NotSent.new("media_failed", "LinkedIn could not report the video's status (#{code})")
      end

      data = code == 404 ? {} : parse(response.body)
      case data["status"]
      when "AVAILABLE" then return
      when "PROCESSING_FAILED"
        raise NotSent.new("media_failed", "LinkedIn could not process the video: #{data['processingFailureReason'] || 'no reason given'}".truncate(300))
      end
      raise NotSent.new("media_failed", "LinkedIn had not reported the video as available after #{VIDEO_POLL_LIMIT.inspect}; nothing was posted") if Time.current > deadline

      on_progress.call
      sleeper.call(VIDEO_POLL_INTERVAL)
    end
  rescue *IN_FLIGHT_ERRORS => e
    raise NotSent.new("media_failed", "LinkedIn could not be reached while the video was processing (#{e.class.name.demodulize})")
  end

  def rest_json(method, path, body, label:, allow_empty: false)
    response = begin
      perform(method, URI("#{API_BASE}#{path}"), body.to_json)
    rescue *IN_FLIGHT_ERRORS => e
      raise NotSent.new("media_failed", "LinkedIn could not be reached during the #{label} (#{e.class.name.demodulize})")
    end
    code = response.code.to_i
    unless code.between?(200, 299)
      reason = { 401 => "unauthorized", 403 => "forbidden", 429 => "rate_limited" }.fetch(code, "media_failed")
      raise NotSent.new(reason, "LinkedIn refused the #{label} (#{code}). #{error_detail(response)}".strip)
    end
    data = parse(response.body)
    raise NotSent.new("media_failed", "LinkedIn's #{label} answer was unreadable") if data.empty? && !allow_empty

    data
  end

  def put_bytes(url, bytes, content_type:, label:)
    uri = URI(url)
    raise NotSent.new("media_failed", "LinkedIn gave an upload URL outside linkedin.com") unless uri.is_a?(URI::HTTPS) && uri.host.to_s.match?(/(\A|\.)linkedin\.com\z/)

    response = begin
      perform(:put, uri, bytes, content_type:)
    rescue *IN_FLIGHT_ERRORS => e
      raise NotSent.new("media_failed", "The #{label} was interrupted (#{e.class.name.demodulize})")
    end
    raise NotSent.new("media_failed", "LinkedIn refused the #{label} (#{response.code})") unless response.code.to_i.between?(200, 299)

    response
  end

  def perform(method, uri, body = nil, content_type: "application/json")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.open_timeout = 10
    http.read_timeout = 60
    http.write_timeout = 120
    http.max_retries = 0
    begin
      http.start
    rescue *CONNECT_ERRORS => e
      raise NotSent.new("unreachable", "LinkedIn could not be reached (#{e.class.name.demodulize})")
    end

    request = { get: Net::HTTP::Get, post: Net::HTTP::Post, put: Net::HTTP::Put }.fetch(method).new(uri)
    request["Authorization"] = "Bearer #{access_token}"
    if uri.host == "api.linkedin.com"
      request["Linkedin-Version"] = VERSION
      request["X-Restli-Protocol-Version"] = "2.0.0"
    end
    if body
      request["Content-Type"] = content_type
      request.body = body
    end
    http.request(request)
  ensure
    http.finish if http&.started?
  end

  def parse(body)
    parsed = JSON.parse(body.to_s)
    parsed.is_a?(Hash) ? parsed : {}
  rescue JSON::ParserError
    {}
  end

  def error_detail(response)
    data = parse(response.body)
    [ data["message"], data["code"], data["serviceErrorCode"] ].select { |part| part.is_a?(String) }.uniq.join(": ").truncate(300)
  end

end
