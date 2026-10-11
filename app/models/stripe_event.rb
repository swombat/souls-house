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

  def self.record!(stripe_event_id:, event_type:, payload:)
    create_or_find_by!(stripe_event_id: stripe_event_id) do |event|
      event.event_type = event_type
      event.payload = payload
    end
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
