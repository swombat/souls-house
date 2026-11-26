# An outgoing visit from a resident hosted here to an account on another
# souls.house deployment. The visit token is encrypted at rest and never
# handed to the resident's container or prompt; the home server makes every
# outbound request on the resident's behalf through Visits::Client.
class Visit < ApplicationRecord

  STATUSES = %w[active ended revoked].freeze
  DEFAULT_MAX_WAKES_PER_HOUR = 12
  MAX_WAKES_PER_HOUR_LIMIT = 60
  RESIDENT_MAX_WAKES_PER_HOUR = 30

  belongs_to :agent
  belongs_to :created_by, class_name: "User", optional: true
  has_many :visit_wakes, dependent: :destroy

  encrypts :visit_token

  scope :active, -> { where(status: "active") }

  validates :visited_origin, presence: true
  validates :visit_token, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :max_wakes_per_hour,
    numericality: { only_integer: true, greater_than_or_equal_to: 1, less_than_or_equal_to: MAX_WAKES_PER_HOUR_LIMIT }
  validate :visited_origin_must_be_http_origin

  def active?
    status == "active"
  end

  def wakes_in_last_hour
    visit_wakes.where("created_at >= ?", 1.hour.ago).count
  end

  def resident_wakes_in_last_hour
    VisitWake.joins(:visit)
      .where(visits: { agent_id: agent_id })
      .where("visit_wakes.created_at >= ?", 1.hour.ago)
      .count
  end

  # Home-side cap on how often visits may wake a resident: both per-visit
  # and across all visits for this resident.
  def wake_cap_reached?
    wakes_in_last_hour >= max_wakes_per_hour ||
      resident_wakes_in_last_hour >= RESIDENT_MAX_WAKES_PER_HOUR
  end

  def mark_ended!(status: "ended", error: nil)
    raise ArgumentError, "invalid end status: #{status}" unless %w[ended revoked].include?(status)

    attrs = { status: status, ended_at: ended_at || Time.current }
    attrs[:last_error] = error.to_s.truncate(250) if error.present?
    update!(attrs)
  end

  def leave!(client: Visits::Client.new)
    if active?
      begin
        client.leave(self)
      rescue Visits::Client::Error => e
        Rails.logger.warn "[Visit] leave remote failed for visit #{id}: #{e.class}: #{e.message}"
      end
    end
    mark_ended!(status: "ended")
  end

  def record_poll_success!
    update!(last_polled_at: Time.current, last_error: nil, consecutive_errors: 0)
  end

  def record_poll_error!(message)
    update!(
      last_polled_at: Time.current,
      last_error: message.to_s.truncate(250),
      consecutive_errors: consecutive_errors + 1
    )
  end

  # Never expose visit_token in serialized responses.
  def as_json(*)
    {
      id: to_param,
      agent_id: agent.to_param,
      visited_origin: visited_origin,
      visited_house_name: visited_house_name,
      visited_account_name: visited_account_name,
      local_name: local_name,
      status: status,
      max_wakes_per_hour: max_wakes_per_hour,
      ended_at: ended_at&.iso8601,
      last_polled_at: last_polled_at&.iso8601,
      last_wake_at: last_wake_at&.iso8601,
      last_error: last_error,
      created_at: created_at&.iso8601
    }
  end

  private

  def visited_origin_must_be_http_origin
    return if visited_origin.blank?

    uri = URI.parse(visited_origin)
    unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.blank? && uri.query.blank? && uri.fragment.blank?
      errors.add(:visited_origin, "must be a valid http(s) origin")
    end
  rescue URI::InvalidURIError
    errors.add(:visited_origin, "must be a valid http(s) origin")
  end

end
