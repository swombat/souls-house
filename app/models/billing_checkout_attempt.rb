# Immutable payment intent, committed before contacting Stripe. Unknown attempts
# remain blocking: never rotate their key because a replay was refused.
class BillingCheckoutAttempt < ApplicationRecord

  belongs_to :agent
  belongs_to :account
  belongs_to :billing_code_redemption, optional: true

  attr_readonly :agent_id, :account_id, :billing_code_redemption_id, :tier, :rate,
    :stripe_price_id, :idempotency_key, :create_params

  validates :tier, :rate, :stripe_price_id, :idempotency_key, :create_params, presence: true
  scope :unresolved, -> { where(resolved_at: nil) }

end
