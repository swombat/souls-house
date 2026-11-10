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

  # Statuses in which a standard-rate subscription can carry the account's
  # house-model allowance: paid, or past_due (the resident's grace). An
  # incomplete one has paid nothing yet.
  CARRIER_STATUSES = %w[trialing active past_due].freeze

  scope :live, -> { where(stripe_status: LIVE_STATUSES) }
  scope :can_carry_allowance, -> { where(rate: "standard", stripe_status: CARRIER_STATUSES) }

  def live? = stripe_status.in?(LIVE_STATUSES)
  def paid? = stripe_status.in?(PAID_STATUSES)
  def ended? = stripe_status.in?(ENDED_STATUSES)
  def trialing? = stripe_status == "trialing"

  # When the free trial ends, while it runs; nil otherwise.
  def trial_ends_at = trialing? ? trial_end : nil

  def tier_record = Billing::Tier.find(tier)

  def offer = tier_record&.offer(rate)

  def can_carry_allowance? = rate == "standard" && stripe_status.in?(CARRIER_STATUSES)

  # What this subscription brings of the account's house-model allowance:
  # all of it for the one carrying it, whatever its size; nothing for any
  # other, and never anything at cost.
  def allowance_usd
    includes_allowance? && can_carry_allowance? ? Billing::Tier::ACCOUNT_ALLOWANCE_USD : BigDecimal("0")
  end

end
