# Immutable payment intent, committed before contacting Stripe. Unknown attempts
# remain blocking: never rotate their key because a replay was refused.
#
# kind "checkout" opens a Stripe Checkout (Billing::Checkout); kind "item"
# adds the resident to the account's live subscription (Billing::AddItem):
# stripe_subscription_id is that parent, create_params its pinned update,
# quote what the owner was shown, submitted_at when it was first sent. kind
# "end" ends the resident's plan on that subscription (Billing::EndItem):
# stripe_subscription_item_id is the item it ends, create_params the pinned
# delete or period-end update, quote names the operation.
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
