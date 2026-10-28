# A Stripe subscription that pays for one hosted resident. One row per Stripe
# subscription, never reused. Only the entitlement's current subscription can
# change what the resident is entitled to.
class ResidentSubscription < ApplicationRecord

  LIVE_STATUSES = %w[incomplete trialing active past_due].freeze
  PAID_STATUSES = %w[trialing active].freeze
  ENDED_STATUSES = %w[canceled unpaid incomplete_expired].freeze

  belongs_to :agent
  belongs_to :account

  validates :stripe_subscription_id, presence: true, uniqueness: true
  validates :stripe_status, presence: true
  validates :tier, inclusion: { in: ->(_) { Billing::Tier.all.map(&:id) } }
  validates :rate, inclusion: { in: Billing::Tier::RATES }

  scope :live, -> { where(stripe_status: LIVE_STATUSES) }

  def live? = stripe_status.in?(LIVE_STATUSES)
  def paid? = stripe_status.in?(PAID_STATUSES)
  def ended? = stripe_status.in?(ENDED_STATUSES)

  def tier_record = Billing::Tier.find(tier)

  def offer = tier_record&.offer(rate)

end
