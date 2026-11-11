# Immutable intent to buy an account plan, committed before contacting
# Stripe (as BillingCheckoutAttempt is for a resident). An unresolved attempt
# blocks a new one: its key is replayed, never rotated.
class AccountPlanCheckoutAttempt < ApplicationRecord

  belongs_to :account

  attr_readonly :account_id, :plan, :stripe_price_id, :idempotency_key, :create_params

  validates :plan, :stripe_price_id, :idempotency_key, :create_params, presence: true
  scope :unresolved, -> { where(resolved_at: nil) }

end
