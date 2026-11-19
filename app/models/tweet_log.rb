class TweetLog < ApplicationRecord

  STATUSES = %w[pending posted failed outcome_unknown resolved_posted resolved_not_posted].freeze
  # A pending post is still being sent, or its sender was interrupted. A
  # live sender finishes within about two minutes of its last touch, and it
  # rechecks under this row's lock before sending, so after this long with
  # no activity a pending post can be resolved like an unknown one.
  PENDING_RESOLVABLE_AFTER = 10.minutes
  # A media post waits in the job queue, uploads and waits for X to process
  # it, touching the row as it goes; it gets longer before it is resolvable.
  MEDIA_PENDING_RESOLVABLE_AFTER = 20.minutes
  MEDIA_KINDS = %w[image video].freeze

  belongs_to :x_integration
  belongs_to :agent
  belongs_to :resolved_by_agent, class_name: "Agent", optional: true

  has_one_attached :media

  validates :tweet_id, uniqueness: true, allow_nil: true
  validates :tweet_id, presence: true, if: -> { status.in?(%w[posted resolved_posted]) }
  validates :text, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :media_kind, inclusion: { in: MEDIA_KINDS }, allow_nil: true

  scope :recent, -> { order(created_at: :desc) }
  scope :outcome_unknown, -> { where(status: "outcome_unknown") }

  def url
    return unless tweet_id

    handle = x_integration.x_username.presence || "i/web"
    "https://x.com/#{handle}/status/#{tweet_id}"
  end

  def resolve!(resolution:, by:, tweet_id: nil)
    with_lock do
      unless resolvable?
        raise ArgumentError, "Only a post whose outcome is unknown, or one left pending with no activity for #{pending_resolvable_after.inspect}, can be resolved"
      end

      case resolution
      when "posted"
        raise ArgumentError, "A numeric tweet id is required" unless tweet_id.to_s.match?(XPoster::TWEET_ID_PATTERN)

        update!(status: "resolved_posted", tweet_id: tweet_id.to_s, resolved_at: Time.current, resolved_by_agent: by)
      when "not_posted"
        update!(status: "resolved_not_posted", resolved_at: Time.current, resolved_by_agent: by)
      else
        raise ArgumentError, "resolution must be posted or not_posted"
      end
    end
    media.purge_later if media.attached?
  end

  def pending_resolvable_after = media_kind ? MEDIA_PENDING_RESOLVABLE_AFTER : PENDING_RESOLVABLE_AFTER

  def resolvable?(now: Time.current)
    status == "outcome_unknown" || (status == "pending" && updated_at <= now - pending_resolvable_after)
  end

  def resolvable_at
    return updated_at + pending_resolvable_after if status == "pending"

    Time.current if status == "outcome_unknown"
  end

  def as_post_json
    {
      id: to_param,
      status:,
      text:,
      reply_to: reply_to_tweet_id,
      media_kind:,
      media_filename:,
      tweet_id:,
      url:,
      failure_reason:,
      error: error_message,
      created_at: created_at&.iso8601,
      resolved_at: resolved_at&.iso8601,
      resolvable_at: resolvable_at&.iso8601
    }
  end

end
