# Every Stripe webhook event, recorded before it is applied. A Stripe retry of
# an event we recorded but never finished is a recovery path, not a duplicate.
class StripeEvent < ApplicationRecord

  STATUSES = %w[received processing processed failed].freeze
  MAX_ATTEMPTS = 5
  STUCK_AFTER = 10.minutes

  # Uniqueness is the index's job: create_or_find_by! relies on the insert failing.
  validates :stripe_event_id, presence: true
  validates :event_type, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :unfinished, -> { where(status: %w[received processing failed]) }
  scope :retryable, ->(now = Time.current) {
    unfinished.where(updated_at: ..(now - STUCK_AFTER)).where(attempts: ...MAX_ATTEMPTS)
  }
  # A worker that died mid-attempt on its last try: nothing else will pick it up.
  scope :abandoned, ->(now = Time.current) {
    where(status: "processing", updated_at: ..(now - STUCK_AFTER)).where(attempts: MAX_ATTEMPTS..)
  }

  def self.record!(stripe_event_id:, event_type:, payload:)
    create_or_find_by!(stripe_event_id: stripe_event_id) do |event|
      event.event_type = event_type
      event.payload = payload
    end
  end

  # Atomically takes an event for one attempt. Received and failed events can
  # be claimed, and so can one left in processing past STUCK_AFTER (its worker
  # died). Returns the claimed attempt number, or nil if another worker holds
  # it or it is already processed. The attempt number comes back from the same
  # UPDATE, so a worker stalled after claiming can't read a newer worker's.
  def self.claim(id, now: Time.current)
    sql = sanitize_sql_array([ <<~SQL, now, id, now - STUCK_AFTER ])
      UPDATE stripe_events SET status = 'processing', attempts = attempts + 1, updated_at = ?
      WHERE id = ? AND (status IN ('received', 'failed') OR (status = 'processing' AND updated_at <= ?))
      RETURNING attempts
    SQL
    connection.select_value(sql)&.to_i
  end

  # Records the outcome of an attempt, only if that attempt still owns the
  # event, so a late worker can't overwrite a newer result.
  def finish!(attempt:, status:, error: nil, now: Time.current)
    self.class.where(id: id, status: "processing", attempts: attempt).update_all(
      status: status, last_error: error, processed_at: (status == "processed" ? now : nil), updated_at: now
    ) == 1
  end

  def recoverable?(now = Time.current)
    status.in?(%w[received failed]) || (status == "processing" && updated_at <= now - STUCK_AFTER)
  end

  def processed? = status == "processed"

  # The subscription this event is about, wherever Stripe put it for this
  # object type. Events about anything else are recorded and ignored.
  def subscription_id
    object = payload.dig("data", "object") || {}
    case object["object"]
    when "subscription" then object["id"]
    when "checkout.session" then object["subscription"]
    when "invoice"
      object["subscription"].presence || object.dig("parent", "subscription_details", "subscription")
    end
  end

end
