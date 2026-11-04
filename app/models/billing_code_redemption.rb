# One account's use of one billing code: the grant itself. While it is live
# (not withdrawn), the account may buy plans at the rate its effect names.
# Withdrawing it stops future purchases at that rate; subscriptions already
# bought are never changed by it.
class BillingCodeRedemption < ApplicationRecord

  belongs_to :account
  belongs_to :billing_code
  belongs_to :redeemed_by, class_name: "User"
  belongs_to :withdrawn_by, class_name: "User", optional: true

  validates :effect, inclusion: { in: BillingCode::EFFECTS }
  validates :billing_code_id, uniqueness: { scope: :account_id }

  scope :live, -> { where(withdrawn_at: nil) }

  def live? = withdrawn_at.nil?

  def withdraw!(by:, now: Time.current)
    update!(withdrawn_at: now, withdrawn_by: by) if live?
  end

  def as_json(*)
    { id: id, code: billing_code.code, effect: effect, account: account.name, account_id: account.to_param,
      redeemed_by: redeemed_by.display_name, redeemed_at: redeemed_at.iso8601, withdrawn_at: withdrawn_at&.iso8601 }
  end

end
