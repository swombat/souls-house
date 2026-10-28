# One Stripe Checkout attempt for one resident: the idempotency key the house
# sent, the offer, and the grant it was authorised by, written before Stripe
# is called. The session id arrives when Stripe answers; an attempt without
# one had its answer lost and is recovered by replaying its key; one whose
# key can no longer be replayed is abandoned (Billing::Checkout).
class CheckoutAttempt < ApplicationRecord

  belongs_to :agent
  belongs_to :billing_code_redemption, optional: true

  validates :idempotency_key, presence: true, uniqueness: true
  validates :offer_id, presence: true

  scope :unresolved, -> { where(stripe_session_id: nil, abandoned_at: nil) }

  def resolved? = stripe_session_id.present?

end
