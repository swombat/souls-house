# Immutable payment intent, committed before contacting Stripe. Unknown attempts
# remain blocking: never rotate their key because a replay was refused.
#
# kind "checkout" opens a Stripe Checkout (Billing::Checkout). The kinds
# "item", "end" and "keep" were changes to a bill that already existed; those
# are bill changes now (BillChange, Billing::Reconcile) and are no longer
# written. Their old rows are kept as the record of what was done.
class BillingCheckoutAttempt < ApplicationRecord

  belongs_to :agent
  belongs_to :account
  belongs_to :billing_code_redemption, optional: true

  attr_readonly :agent_id, :account_id, :billing_code_redemption_id, :tier, :rate,
    :stripe_price_id, :idempotency_key, :create_params, :kind, :stripe_subscription_id, :quote

  validates :tier, :rate, :stripe_price_id, :idempotency_key, :create_params, presence: true
  validates :kind, inclusion: { in: %w[checkout item end keep] }
  validates :stripe_subscription_id, :quote, presence: true, if: -> { kind.in?(%w[item end keep]) }
  validates :stripe_subscription_item_id, presence: true, if: -> { kind == "end" }
  scope :unresolved, -> { where(resolved_at: nil) }

  def item? = kind == "item"

end
