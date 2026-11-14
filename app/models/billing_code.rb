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
    (Billing::AccountPlan.all - [ Billing::AccountPlan.default ]).map { |plan| "plan:#{plan.id}" }).freeze
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
  def self.effects_for(offer) = [ offer.rate, "#{offer.rate}:#{offer.tier.id}" ]

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
  # one account from redeeming the same code twice.
  def self.redeem!(code:, account:, by:, now: Time.current)
    normalized = code.to_s.strip.upcase
    transaction do
      record = lock.find_by("lower(code) = ?", normalized.downcase)
      raise Refused, "That code isn't one this house knows." if record.nil?
      raise Refused, "This account has already used that code." if record.redemptions.exists?(account: account)
      raise Refused, record.refusal(now) unless record.redeemable?(now)
      raise Refused, record.paid_plan_refusal(account) if record.paid_plan_refusal(account)

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
  # go on charging for what the code gives. The owner ends that first.
  def paid_plan_refusal(account)
    plan = self.class.plan_of(effect)
    paid = plan && account.account_subscriptions.live.order(:id).last
    return nil unless paid && paid.plan_record <= plan

    "This code gives the #{plan.name} plan free, and this account is paying for #{paid.plan_record.name}. " \
      "Move the account to #{Billing::AccountPlan.default.name} in Billing first, then use the code, so nothing is charged twice."
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
