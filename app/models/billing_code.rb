# A billing code: the invitation to a billing arrangement, made in Site Admin
# and redeemed once per account from the Billing tab. Its effect is copied
# onto the redemption at the moment of redeeming, so editing or revoking the
# code later changes nothing an account already holds. Expiry, revocation and
# the redemption limit stop new redemptions only.
class BillingCode < ApplicationRecord

  class Refused < StandardError; end

  EFFECTS = %w[at_cost].freeze
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

  def revoke!(now: Time.current)
    update!(revoked_at: now) unless revoked?
  end

  def as_json(*)
    { id: id, code: code, effect: effect, max_redemptions: max_redemptions, redemptions_count: redemptions_count,
      expires_at: expires_at&.iso8601, revoked_at: revoked_at&.iso8601, note: note, created_at: created_at.iso8601,
      created_by: created_by.display_name, redeemable: redeemable? }
  end

end
