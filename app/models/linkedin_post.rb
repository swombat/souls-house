# One post a resident asked the house to publish to a LinkedIn member
# profile (LinkedinPoster). Statuses mirror TweetLog: a post whose fate is
# unknown is never retried automatically and waits to be resolved.
class LinkedinPost < ApplicationRecord

  STATUSES = %w[pending posted failed outcome_unknown resolved_posted resolved_not_posted].freeze
  MEDIA_KINDS = %w[image video].freeze
  # A media post can spend minutes uploading and waiting for LinkedIn to
  # process the video, touching the row as it goes; after this long with no
  # activity a pending post can be resolved like an unknown one.
  PENDING_RESOLVABLE_AFTER = 20.minutes
  POST_URN_PATTERN = /\Aurn:li:(?:share|ugcPost):\d{1,30}\z/

  belongs_to :service_connection
  belongs_to :agent
  belongs_to :resolved_by_agent, class_name: "Agent", optional: true

  has_one_attached :media

  validates :text, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :media_kind, inclusion: { in: MEDIA_KINDS }, allow_nil: true
  validates :post_urn, uniqueness: true, allow_nil: true
  validates :post_urn, presence: true, if: -> { status.in?(%w[posted resolved_posted]) }

  # A post URL (https://www.linkedin.com/feed/update/urn:li:share:123/) or
  # the URN itself, to the URN.
  def self.urn_from(value)
    CGI.unescape(value.to_s)[/urn:li:(?:share|ugcPost):\d{1,30}/]
  end

  def url
    "https://www.linkedin.com/feed/update/#{post_urn}/" if post_urn
  end

  def resolve!(resolution:, by:, post_urn: nil)
    with_lock do
      unless resolvable?
        raise ArgumentError, "Only a post whose outcome is unknown, or one left pending with no activity for #{PENDING_RESOLVABLE_AFTER.inspect}, can be resolved"
      end

      case resolution
      when "posted"
        raise ArgumentError, "A LinkedIn post URL or urn:li:share/ugcPost id is required" unless post_urn.to_s.match?(POST_URN_PATTERN)

        update!(status: "resolved_posted", post_urn:, resolved_at: Time.current, resolved_by_agent: by)
      when "not_posted"
        update!(status: "resolved_not_posted", resolved_at: Time.current, resolved_by_agent: by)
      else
        raise ArgumentError, "resolution must be posted or not_posted"
      end
    end
    media.purge_later if media.attached?
  end

  def resolvable?(now: Time.current)
    status == "outcome_unknown" || (status == "pending" && updated_at <= now - PENDING_RESOLVABLE_AFTER)
  end

  def resolvable_at
    return updated_at + PENDING_RESOLVABLE_AFTER if status == "pending"

    Time.current if status == "outcome_unknown"
  end

  def as_post_json
    {
      id: to_param,
      status:,
      text:,
      media_kind:,
      media_filename:,
      post_urn:,
      url:,
      failure_reason:,
      error: error_message,
      created_at: created_at&.iso8601,
      resolved_at: resolved_at&.iso8601,
      resolvable_at: resolvable_at&.iso8601
    }
  end

end
