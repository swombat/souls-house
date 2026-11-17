# A billing code: the invitation to a billing arrangement, made in Site Admin
# and redeemed once per account from the Billing tab. Its effect is copied
# onto the redemption at the moment of redeeming, so editing or revoking the
# code later changes nothing an account already holds. Expiry, revocation and
# the redemption limit stop new redemptions only.
class BillingCode < ApplicationRecord

  class Refused < StandardError; end

  # What a code can grant: plans at cost, for every size or for one, or an
  # account plan with nothing to pay for it.
  EFFECTS = ([ "at_cost" ] + Billing::Tier.all.map { |tier| "at_cost:#{tier.id}" } +
    Billing::AccountPlan.all.map { |plan| "plan:#{plan.id}" }).freeze
  FORMAT = /\A[A-Z0-9][A-Z0-9-]{2,39}\z/

  belongs_to :created_by, class_name: "User"
  has_many :redemptions, class_name: "BillingCodeRedemption", dependent: :restrict_with_error

  before_validation { self.code = code.to_s.strip.upcase }

  validates :code, presence: true, format: { with: FORMAT, message: "is letters, digits and dashes, 3 to 40 long" },
    uniqueness: { case_sensitive: false }
  validates :effect, inclusion: { in: EFFECTS }
  validates :max_redemptions, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true

  scope :by_recency, -> { order(created_at: :desc) }

  # A code nobody has to think up: ten characters, unambiguous, unique here.
  def self.generate
    loop do
      candidate = SecureRandom.alphanumeric(10).upcase.tr("0O1I", "ZXYW")
      return candidate unless where("lower(code) = ?", candidate.downcase).exists?
    end
  end

  # The effects that let an account buy an offer at other than the standard rate.
  # An at-cost grant covers both at-cost rates: which one a resident pays is
  # the machine it lives on (Billing::Tier::AT_COST_RATES), not the code.
  def self.effects_for(offer)
    rate = offer.at_cost? ? "at_cost" : offer.rate
    [ rate, "#{rate}:#{offer.tier.id}" ]
  end

  # The account plan an effect grants, or nil.
  def self.plan_of(effect)
    effect.to_s.start_with?("plan:") ? Billing::AccountPlan.find(effect.to_s.delete_prefix("plan:")) : nil
  end

  def self.label(effect)
    kind, id = effect.to_s.split(":", 2)
    return "The #{Billing::AccountPlan.find(id)&.name || id} plan, free" if kind == "plan"
    return "At cost, #{Billing::Tier.find(id)&.name || id} only" if id

    "At cost, every size"
  end

  # Redeems a code for an account, atomically: the code row is locked, so two
  # accounts can't both take the last redemption, and the unique index keeps
  # one account from redeeming the same code twice. It waits for the
  # account's billing lock, so a purchase can't pass it half way.
  def self.redeem!(code:, account:, by:, now: Time.current)
    normalized = code.to_s.strip.upcase
    transaction do
      Billing::BillSync.lock!(account.id)
      record = lock.find_by("lower(code) = ?", normalized.downcase)
      raise Refused, "That code isn't one this house knows." if record.nil?
      raise Refused, "This account has already used that code." if record.redemptions.exists?(account: account)
      raise Refused, record.refusal(now) unless record.redeemable?(now)
      raise Refused, record.plan_refusal(account) if record.plan_refusal(account)

      redemption = record.redemptions.create!(account: account, effect: record.effect, redeemed_by: by, redeemed_at: now)
      record.update!(redemptions_count: record.redemptions_count + 1)
      redemption
    end
  end

  def revoked? = revoked_at.present?
  def expired?(now = Time.current) = expires_at.present? && expires_at <= now
  def exhausted? = max_redemptions.present? && redemptions_count >= max_redemptions
  def redeemable?(now = Time.current) = !revoked? && !expired?(now) && !exhausted?

  def refusal(now = Time.current)
    return "That code has been withdrawn." if revoked?
    return "That code has expired." if expired?(now)
    return "That code has been used as many times as it can be." if exhausted?

    nil
  end

  # A free plan is never laid over a paid one it covers: the paid line would
  # go on charging for what the code gives. So it waits until nothing the
  # account pays, or could still pay, is for that plan or a lower one: a plan
  # row not truly ended (an unpaid one comes back when its bill is paid), a
  # Checkout still open, a change to the bill already sent.
  PLAN_OVER = %w[canceled incomplete_expired].freeze

  def plan_refusal(account)
    plan = self.class.plan_of(effect)
    return nil unless plan

    paid = account.account_subscriptions.where.not(stripe_status: PLAN_OVER).order(:id).last
    if paid && paid.plan_record <= plan
      return "This code gives the #{plan.name} plan free, and this account is paying for #{paid.plan_record.name}. " \
        "Write to #{Billing.contact_email} to move it onto the code, so nothing is charged twice."
    end
    if AccountPlanCheckoutAttempt.unresolved.exists?(account:) || first_bill_with_plan_open?(account) ||
        BillChange.submitted.where(account:).any? { |change| change.ops.any? { |op| op["op"] == "plan" } }
      return "A payment for this account's plan is still being confirmed. Try the code again in a few minutes."
    end

    nil
  end

  # A first bill that charges a plan and could still be paid: a resident's
  # Checkout naming a plan, or a paid creation's order carrying one. A code
  # that gives the plan free waits until it is paid or dropped, so the plan
  # is never both given and charged.
  def first_bill_with_plan_open?(account)
    ResidentBirthOrder.where(account:, state: %w[pending failed]).where.not(plan_stripe_price_id: nil).exists? ||
      BillingCheckoutAttempt.unresolved.where(account:).any? { |attempt| attempt.create_params.dig("metadata", "plan").present? }
  end

  def revoke!(now: Time.current)
    update!(revoked_at: now) unless revoked?
  end

  def as_json(*)
    { id: id, code: code, effect: effect, effect_label: self.class.label(effect), max_redemptions: max_redemptions, redemptions_count: redemptions_count,
      expires_at: expires_at&.iso8601, revoked_at: revoked_at&.iso8601, note: note, created_at: created_at.iso8601,
      created_by: created_by.display_name, redeemable: redeemable? }
  end

end
