# A resident asked for in an account that pays per resident, waiting for its
# first payment. Nothing is born until Stripe says the plan is paid: then
# Billing::PaidBirth creates the resident through the ordinary birth and
# attaches the subscription to it.
#
# pending   the subscription exists at Stripe and its first invoice is open
# born      paid, and the resident exists (agent_id)
# failed    paid, but the birth itself failed; a site admin is told, and the
#           owner can retry. The payment is never lost track of.
# abandoned never paid before expires_at; its subscription is cancelled
#
# The draft (birth_attributes) holds the soul seed, so it is cleared as soon
# as the order is settled either way.
class ResidentBirthOrder < ApplicationRecord

  # Stripe expires an unpaid first invoice after about 23 hours.
  LIFETIME = 23.hours

  belongs_to :account
  belongs_to :creator, class_name: "User"
  belongs_to :agent, optional: true
  belongs_to :billing_code_redemption, optional: true

  state_machine :state, initial: :pending, action: nil do
    state :pending, :born, :abandoned, :failed

    event :complete_order do
      transition [ :pending, :failed ] => :born
    end

    event :abandon_order do
      transition pending: :abandoned
    end

    event :fail_order do
      transition [ :pending, :failed ] => :failed
    end
  end

  validates :tier, inclusion: { in: ->(_) { Billing::Tier.all.map(&:id) } }
  validates :rate, inclusion: { in: Billing::Tier::RATES }

  scope :pending, -> { where(state: "pending") }
  scope :expired, ->(now = Time.current) { pending.where(expires_at: ..now) }

  before_validation { self.expires_at ||= LIFETIME.from_now }
  # The order's name at Stripe (see the migration that added it): random, so
  # unique across every environment sharing a Stripe account.
  before_validation(on: :create) { self.reference ||= SecureRandom.uuid }

  # Billing::PaidBirth owns the payment checks and enclosing birth transaction.
  def mark_born!(agent:, now: Time.current)
    complete_order!
    update!(agent: agent, born_at: now, birth_attributes: {}, last_error: nil)
  end

  def abandon!
    abandon_order!
    update!(birth_attributes: {})
  end

  def record_failure!(message)
    fail_order!
    update!(last_error: message.first(500))
  end

  def tier_record = Billing::Tier.find!(tier)

  def offer = tier_record.offer(rate)

  def resident_name = birth_attributes["name"]

  def as_json(*)
    { id: to_param, state: state, tier: tier, rate: rate, resident_name: resident_name, expires_at: expires_at&.iso8601,
      last_error: last_error }
  end

  private

  private :complete_order, :complete_order!, :abandon_order, :abandon_order!, :fail_order, :fail_order!

end
