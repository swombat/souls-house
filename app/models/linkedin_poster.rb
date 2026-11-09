# Publishes one post to a LinkedIn member profile for a resident, through a
# LinkedIn connection the resident has been given access to (the owner's
# per-resident switch on the connection's card is the posting switch; it is
# off until the owner turns it on).
#
# Like XPoster: every post needs an idempotency key, and a repeated key
# returns the stored outcome without posting again. A post whose fate cannot
# be known (timeout after the create request was sent, 5xx, an unreadable
# 2xx) is stored as outcome_unknown and never retried; someone resolves it.
#
# Text-only posts are sent inside the request. A post with an image or a
# video is stored with its file and sent by LinkedinPostJob: the upload and
# LinkedIn's video processing can take minutes. Media steps can never
# publish anything, so their failures are plain failures; only the final
# create-post call can leave the outcome unknown.
class LinkedinPoster

  class Refused < StandardError

    attr_reader :code, :http_status

    def initialize(code, message, http_status)
      @code = code
      @http_status = http_status
      super(message)
    end

  end

  Result = Struct.new(:post, :replayed, keyword_init: true)

  MAX_KEY_LENGTH = 200
  MAX_TEXT_LENGTH = 3_000
  RESERVATION_LOCK_SPACE = 7_317
  IMAGE_TYPES = %w[image/jpeg image/png image/gif].freeze
  VIDEO_TYPES = %w[video/mp4].freeze
  MAX_IMAGE_BYTES = 10.megabytes
  # LinkedIn takes up to 500 MB; the house holds the file while it uploads,
  # so it keeps a smaller ceiling.
  MAX_VIDEO_BYTES = 200.megabytes
  MIN_VIDEO_BYTES = 75.kilobytes

  def initialize(agent:)
    @agent = agent
  end

  # media: an uploaded file (ActionDispatch::Http::UploadedFile or anything
  # with original_filename, content_type, size and a readable io).
  def post!(text:, idempotency_key:, media: nil, connection_id: nil)
    text = text.to_s.strip
    media_kind = validate!(text:, idempotency_key:, media:)
    connection = find_connection(connection_id)

    post, replayed = reserve!(connection:, text:, idempotency_key:, media:, media_kind:)
    return Result.new(post:, replayed: true) if replayed

    if media_kind
      LinkedinPostJob.perform_later(post)
    else
      self.class.deliver!(post)
    end
    Result.new(post: post.reload, replayed: false)
  end

  # Sends a reserved post. Called inline for text, from LinkedinPostJob for
  # media. Does nothing unless the post is still pending.
  def self.deliver!(post)
    new(agent: post.agent).send(:deliver, post)
  end

  private

  attr_reader :agent

  def validate!(text:, idempotency_key:, media:)
    if idempotency_key.blank? || idempotency_key.length > MAX_KEY_LENGTH
      raise Refused.new("idempotency_key_required", "An Idempotency-Key header (1-#{MAX_KEY_LENGTH} characters) is required", :bad_request)
    end
    raise Refused.new("text_blank", "Text is empty", :unprocessable_entity) if text.blank?
    if text.length > MAX_TEXT_LENGTH
      raise Refused.new("text_too_long", "Text is #{text.length} characters; LinkedIn allows #{MAX_TEXT_LENGTH}", :unprocessable_entity)
    end
    return nil unless media

    type = media.content_type.to_s.split(";").first.to_s.strip.downcase
    size = media.size.to_i
    if IMAGE_TYPES.include?(type)
      raise Refused.new("media_too_large", "Images can be up to #{MAX_IMAGE_BYTES / 1.megabyte} MB", :unprocessable_entity) if size > MAX_IMAGE_BYTES
      raise Refused.new("media_empty", "The image is empty", :unprocessable_entity) if size.zero?

      "image"
    elsif VIDEO_TYPES.include?(type)
      raise Refused.new("media_too_large", "Videos can be up to #{MAX_VIDEO_BYTES / 1.megabyte} MB", :unprocessable_entity) if size > MAX_VIDEO_BYTES
      raise Refused.new("media_too_small", "LinkedIn needs a video of at least 75 KB", :unprocessable_entity) if size < MIN_VIDEO_BYTES

      "video"
    else
      raise Refused.new("media_type", "Only JPEG, PNG or GIF images and MP4 videos can be posted (got #{type.presence || 'an unknown type'})", :unprocessable_entity)
    end
  end

  def find_connection(connection_id)
    connections = agent.service_connections.merge(AgentServiceAccess.effective).where(provider: "linkedin")
    if connection_id.present?
      found = connections.find { |connection| connection.public_id == connection_id.to_s }
      raise Refused.new("not_connected", "No LinkedIn connection #{connection_id} is shared with you", :forbidden) unless found

      return found
    end

    case connections.size
    when 0
      raise Refused.new("not_connected", "No LinkedIn connection is shared with you; the owner connects LinkedIn and turns you on for it in Integrations", :forbidden)
    when 1
      connections.first
    else
      ids = connections.map(&:public_id).join(", ")
      raise Refused.new("connection_required", "Several LinkedIn connections are shared with you (#{ids}); choose one with --connection", :unprocessable_entity)
    end
  end

  def reserve!(connection:, text:, idempotency_key:, media:, media_kind:)
    media_digest = media && Digest::SHA256.file(media_path(media)).hexdigest
    digest = Digest::SHA256.hexdigest({ text:, connection: connection.public_id, media_kind:, media_digest: }.to_json)

    LinkedinPost.transaction do
      LinkedinPost.connection.execute(
        LinkedinPost.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?, ?)", RESERVATION_LOCK_SPACE, agent.id ])
      )

      existing = LinkedinPost.find_by(agent:, idempotency_key:)
      if existing
        unless existing.request_digest == digest
          raise Refused.new("idempotency_key_reused", "This Idempotency-Key was already used for a different post", :unprocessable_entity)
        end
        return [ existing, true ]
      end

      unless connection.reload.status == "connected"
        raise Refused.new("reconnect_needed", Services::LinkedinAdapter.expired_message(connection.grant_expires_at), :conflict)
      end

      post = connection.linkedin_posts.create!(
        agent:, text:, idempotency_key:, request_digest: digest, status: "pending",
        media_kind:, media_filename: media&.original_filename.to_s.truncate(200).presence
      )
      post.media.attach(io: File.open(media_path(media)), filename: media.original_filename.presence || "upload", content_type: media.content_type) if media
      [ post, false ]
    end
  end

  def media_path(media)
    media.respond_to?(:tempfile) ? media.tempfile.path : media.path
  end

  def deliver(post)
    return unless claim(post)

    # A first look before the (possibly long) upload, so a post that could
    # never be sent fails fast. It decides nothing: access, connection and
    # token are all checked again, under locks, at the create-post boundary.
    connection = post.service_connection
    return access_removed!(post) unless effective_access?(connection)

    adapter = connection.definition.adapter
    if post.media_kind
      uploader = LinkedinPublisher.new(
        access_token: adapter.current_access_token(connection),
        author_urn: adapter.author_urn(connection),
        on_progress: -> { post.touch }
      )
      media_urn = upload_media(post, uploader)
    end
    publish(post, media_urn)
  rescue Services::LinkedinAdapter::Expired => e
    mark_reauthorizing(post.service_connection)
    finish!(post, status: "failed", failure_reason: "reconnect_needed", error_message: e.message.truncate(500))
  rescue Services::AdapterError, ArgumentError => e
    finish!(post, status: "failed", failure_reason: "token_unavailable", error_message: "Nothing was sent: #{e.message}".truncate(500))
  rescue LinkedinPublisher::NotSent => e
    mark_reauthorizing(post.service_connection) if e.reason == "unauthorized"
    finish!(post, status: "failed", failure_reason: e.reason, error_message: e.message.truncate(500))
  ensure
    post.media.purge_later if post&.media&.attached? && !post.reload.status.in?(%w[pending])
  end

  # Only a pending post is sent; touching it restarts the quiet period a
  # resolver must wait out.
  def claim(post)
    post.with_lock do
      next false unless post.status == "pending"

      post.touch
      true
    end
  end

  def upload_media(post, publisher)
    post.media.blob.open do |file|
      urn = if post.media_kind == "image"
        publisher.upload_image(file, content_type: post.media.content_type)
      else
        publisher.upload_video(file, size: post.media.byte_size)
      end
      post.update_columns(media_urn: urn, updated_at: Time.current)
      urn
    end
  rescue ActiveStorage::FileNotFoundError
    raise LinkedinPublisher::NotSent.new("media_failed", "Nothing was sent: the stored file is gone")
  end

  # The create-post boundary. Under the post's row lock from the last pending
  # check through recording LinkedIn's answer: a resolver takes the same
  # lock, so it either resolves first (and nothing is sent) or sees the
  # recorded outcome. The connection, the resident's guest seat and access
  # row are locked too (in the order set_service_access! takes them), so a
  # switch-off, disconnect or reconnect either commits first and is seen
  # here, or waits until LinkedIn has answered. The token and author are read
  # from the connection as it is now, not as it was before the upload.
  def publish(post, media_urn)
    LinkedinPost.transaction do
      post.lock!
      next unless post.status == "pending"

      connection = post.service_connection
      adapter = connection.definition.adapter
      # Locks the connection row and raises unless it is still connected.
      token = adapter.current_access_token(connection)
      GuestMembership.lock("FOR SHARE").find_by(agent_id: post.agent_id, account_id: connection.account_id)
      access = AgentServiceAccess.lock.find_by(agent_id: post.agent_id, service_connection_id: connection.id)
      next access_removed!(post) unless access && AgentServiceAccess.effective.exists?(id: access.id)

      publisher = LinkedinPublisher.new(access_token: token, author_urn: adapter.author_urn(connection))
      begin
        urn = publisher.create_post(text: post.text, media_urn:)
        finish!(post, status: "posted", post_urn: urn)
      rescue LinkedinPublisher::OutcomeUnknown => e
        finish!(post, status: "outcome_unknown", failure_reason: "outcome_unknown", error_message: e.message.truncate(500))
      end
    end
  end

  def effective_access?(connection)
    agent.service_connections.merge(AgentServiceAccess.effective).exists?(id: connection.id)
  end

  def access_removed!(post)
    finish!(post, status: "failed", failure_reason: "access_removed",
                  error_message: "Nothing was sent: this resident's access to the LinkedIn connection was switched off")
  end

  def mark_reauthorizing(connection)
    connection.with_lock { connection.update!(status: "reauthorizing") if connection.status == "connected" }
  end

  # The last write lands only while the row is still pending, so a
  # resolution is never overwritten.
  def finish!(post, **attributes)
    updated = LinkedinPost.where(id: post.id, status: "pending").update_all(attributes.merge(updated_at: Time.current))
    return true if updated == 1

    late = "Late answer after resolution: #{attributes.slice(:status, :post_urn, :error_message).compact.to_json}"
    LinkedinPost.where(id: post.id).update_all([ "error_message = CONCAT_WS(' | ', error_message, ?), updated_at = ?", late.truncate(500), Time.current ])
    false
  end

end
