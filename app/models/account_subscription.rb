# A Stripe subscription that pays for an account's plan (Billing::AccountPlan),
# separate from any resident's. One row per Stripe subscription, never reused;
# at most one live per account (Billing::AccountSubscriptionSync keeps it).
# Ending it removes the plan's features only: no resident is touched.
class AccountSubscription < ApplicationRecord

  LIVE_STATUSES = ResidentSubscription::LIVE_STATUSES
  PAID_STATUSES = ResidentSubscription::PAID_STATUSES
  ENDED_STATUSES = ResidentSubscription::ENDED_STATUSES

  belongs_to :account

  validates :stripe_subscription_id, presence: true, uniqueness: true
  validates :stripe_status, presence: true
  validates :plan, inclusion: { in: ->(_) { Billing::AccountPlan.all.reject(&:free?).map(&:id) } }

  scope :live, -> { where(stripe_status: LIVE_STATUSES) }

  def live? = stripe_status.in?(LIVE_STATUSES)
  def paid? = stripe_status.in?(PAID_STATUSES)
  def ended? = stripe_status.in?(ENDED_STATUSES)

  # Whether the plan is in force: paid, or past_due for at most
  # Billing::GRACE_PERIOD from when Stripe first said so (the same grace a
  # resident gets). After that the plan falls back, whatever Stripe says,
  # until it is paid again.
  def in_force?(now = Time.current)
    return true if paid?

    stripe_status == "past_due" && past_due_since.present? && now < past_due_since + Billing::GRACE_PERIOD
  end

  def plan_record = Billing::AccountPlan.find(plan)

  def as_json(*)
    { status: stripe_status, current_period_end: current_period_end&.iso8601, cancel_at_period_end: cancel_at_period_end }
  end

end
