# What one hosted resident is entitled to: hosting and, on a paid plan, a
# monthly house-inference allowance. States and transitions follow the design
# doc (docs/proposals/2026-10-07-stripe-billing.md, "Entitlement states").
#
# Callers apply subscriptions under Billing::SubscriptionSync's per-resident
# advisory lock, so two Stripe fetches can't interleave here.
class ResidentEntitlement < ApplicationRecord

  STATES = %w[pending active grace held complimentary].freeze
  SOURCES = %w[complimentary stripe].freeze

  belongs_to :agent
  belongs_to :account
  belongs_to :current_subscription, class_name: "ResidentSubscription", optional: true

  validates :agent_id, uniqueness: true
  validates :state, inclusion: { in: STATES }
  validates :source, inclusion: { in: SOURCES }
  validates :tier, inclusion: { in: ->(_) { Billing::Tier.all.map(&:id) } }, allow_nil: true

  scope :in_grace, -> { where(state: "grace") }
  scope :grace_expired, ->(now = Time.current) { in_grace.where(grace_deadline: ..now) }

  after_commit :schedule_grace_deadline, if: -> { saved_change_to_grace_deadline? && grace? }

  STATES.each do |name|
    define_method(:"#{name}?") { state == name }
  end

  def self.for_agent!(agent)
    find_or_create_by!(agent: agent) do |entitlement|
      entitlement.account = agent.account
      entitlement.source = "stripe"
      entitlement.state = "pending"
    end
  end

  # Applies a freshly fetched subscription. Returns true when the entitlement
  # changed. Events about a subscription that isn't current change nothing
  # here, so an old subscription's cancellation can't hold a resident whose
  # replacement is paid. A subscription becomes current only once it is paid,
  # so a failed or abandoned first checkout grants nothing.
  def apply_subscription!(subscription, now: Time.current)
    unless current_subscription_id == subscription.id
      return false unless adoptable?(subscription)

      self.current_subscription = subscription
    end

    case subscription.stripe_status
    when *ResidentSubscription::PAID_STATUSES then activate(subscription, now)
    when "past_due" then start_grace(now)
    when *ResidentSubscription::ENDED_STATUSES then end_paid_plan(now)
    end

    changed? ? save! : false
  end

  # The house imposes its grace deadline itself; Stripe may send nothing then.
  # Stripe still saying past_due doesn't matter. The paid plan ends here, the
  # same way it ends on cancellation: free hosting the house granted survives,
  # and the unpaid invoice stays Stripe's business.
  def expire_grace!(now: Time.current)
    with_lock do
      return false unless grace? && grace_deadline.present? && grace_deadline <= now

      end_paid_plan(now)
      save!
    end
  end

  def paid? = source == "stripe" && (active? || grace?)

  def tier_record = tier && Billing::Tier.find(tier)

  def as_json(*)
    subscription = current_subscription
    {
      state: state,
      source: source,
      tier: tier,
      complimentary: complimentary_granted_at.present?,
      grace_deadline: grace_deadline&.iso8601,
      held_at: held_at&.iso8601,
      subscription: subscription && {
        status: subscription.stripe_status,
        tier: subscription.tier,
        current_period_end: subscription.current_period_end&.iso8601,
        cancel_at_period_end: subscription.cancel_at_period_end
      }
    }
  end

  private

  def adoptable?(subscription)
    subscription.paid? && (current_subscription.nil? || !current_subscription.live?)
  end

  def activate(subscription, now)
    self.hold_released_at = now if held?
    self.state = "active"
    self.source = "stripe"
    self.tier = subscription.tier
    self.grace_started_at = nil
    self.grace_deadline = nil
  end

  # Grace starts only from active. Replaying past_due while in grace or held
  # neither restarts grace nor lifts a hold.
  def start_grace(now)
    return unless active?

    self.state = "grace"
    self.grace_started_at = now
    self.grace_deadline = now + Billing::GRACE_PERIOD
  end

  # A paid plan ended. Free hosting the house granted comes back; otherwise
  # the resident is held. Nothing is deleted.
  def end_paid_plan(now)
    self.grace_started_at = nil
    self.grace_deadline = nil
    if complimentary_granted_at.present?
      self.state = "complimentary"
      self.source = "complimentary"
    elsif !held?
      self.state = "held"
      self.held_at = now
    end
  end

  def schedule_grace_deadline
    Billing::GraceDeadlineJob.set(wait_until: grace_deadline).perform_later(id)
  end

end
