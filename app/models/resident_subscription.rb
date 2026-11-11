# One item of a Stripe subscription, paying for one hosted resident. An
# account's residents share one subscription, one item each (eoXAEj); the
# item id is the row's identity. Rows from before have no item id until their
# first sync. Never reused. Only the entitlement's current subscription can
# change what the resident is entitled to.
class ResidentSubscription < ApplicationRecord

  LIVE_STATUSES = %w[incomplete trialing active past_due].freeze
  PAID_STATUSES = %w[trialing active].freeze
  ENDED_STATUSES = %w[canceled unpaid incomplete_expired].freeze

  belongs_to :agent
  belongs_to :account

  validates :stripe_subscription_id, presence: true
  validates :stripe_subscription_item_id, uniqueness: true, allow_nil: true
  validates :stripe_status, presence: true
  validates :tier, inclusion: { in: ->(_) { Billing::Tier.all.map(&:id) } }
  validates :rate, inclusion: { in: Billing::Tier::RATES }

  scope :live, -> { where(stripe_status: LIVE_STATUSES) }

  def live? = stripe_status.in?(LIVE_STATUSES)
  def paid? = stripe_status.in?(PAID_STATUSES)
  def ended? = stripe_status.in?(ENDED_STATUSES)
  def trialing? = stripe_status == "trialing"

  # When the free trial ends, while it runs; nil otherwise.
  def trial_ends_at = trialing? ? trial_end : nil

  def tier_record = Billing::Tier.find(tier)

  def offer = tier_record&.offer(rate)

end
