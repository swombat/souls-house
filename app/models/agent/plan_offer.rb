# The plan offer (#864 slice 3; Daniel, JQwkVe eygZVn, 2026-11-17). When it is
# in force, the first silence nudge of a long conversation run carries one
# extra sentence: the resident may keep a changeable plan with soulshouse-plan
# so others can follow along. There is no wake line, for anyone.
#
# It needs three things: the account's switch (Account#plan_offer_enabled,
# Colleagues only), the owner's switch on this resident, and no "off" from
# the resident. When the owner turns it on, the resident is asked once, in
# its notices (Notices::Renderer), until it answers or ASK_DAYS pass. The
# resident answers with `soulshouse-plan offer on|off`
# (Api::V1::PlanOffersController). Its off beats the owner's on, and a yes
# doesn't bind: it can say off at any time. The owner sees the answer on the
# resident's settings page. Switching the owner's side off and on again asks
# again only if the resident never answered; an answer stays.
module Agent::PlanOffer

  extend ActiveSupport::Concern

  ANSWERS = %w[on off].freeze
  ASK_DAYS = 3
  # Wing's wording (YnwoZe). The same sentence is in agent-runtime's
  # silence_nudge.py and in `soulshouse-plan --help`; a test keeps them equal.
  OFFER = "If you choose to undertake a long task, you can share a changeable plan so others " \
    "can follow along. Optional; no plan is needed for conversation or quiet."

  included do
    validates :plan_offer_answer, inclusion: { in: ANSWERS }, allow_nil: true
    validate :plan_offer_allowed_by_account, if: -> { plan_offer_enabled? && plan_offer_enabled_changed? }
    before_save :stamp_plan_offer_ask, if: -> { plan_offer_enabled? && plan_offer_enabled_changed? }
  end

  # The owner can switch it on for this resident: the account's switch is on
  # and its plan is Colleagues.
  def plan_offer_available?
    account.present? && account.plan_offer_available? && account.plan_offer_enabled?
  end

  # The run's first nudge carries the offer.
  def plan_offer_active?
    plan_offer_enabled? && plan_offer_answer != "off" && plan_offer_available?
  end

  # The owner turned it on and the resident hasn't answered yet, within the
  # days it is asked for.
  def plan_offer_question_open?(now = Time.current)
    plan_offer_active? && plan_offer_answer.nil? && plan_offer_asked_at.present? &&
      plan_offer_asked_at > now - ASK_DAYS.days
  end

  def answer_plan_offer!(answer)
    answer = answer.to_s
    raise ArgumentError, "answer must be on or off" unless answer.in?(ANSWERS)

    update!(plan_offer_answer: answer, plan_offer_answered_at: Time.current)
  end

  # What the owner and the resident see. `state` is one word:
  # unavailable (the account can't have it or hasn't switched it on), off (the owner's switch),
  # declined (the resident said off), asked (on, no answer yet), on.
  def plan_offer_status
    {
      account_plan: account.present? && account.plan_offer_available?,
      available: plan_offer_available?,
      owner_enabled: plan_offer_enabled?,
      answer: plan_offer_answer,
      answered_at: plan_offer_answered_at&.iso8601,
      asked_at: plan_offer_asked_at&.iso8601,
      active: plan_offer_active?,
      state: plan_offer_state
    }
  end

  def plan_offer_state
    return "unavailable" unless plan_offer_available?
    return "off" unless plan_offer_enabled?
    return "declined" if plan_offer_answer == "off"
    return "asked" if plan_offer_answer.nil?

    "on"
  end

  private

  def plan_offer_allowed_by_account
    return if plan_offer_available?

    errors.add(:plan_offer_enabled, "Plans for long tasks come with the Colleagues plan, once the account has switched them on")
  end

  def stamp_plan_offer_ask
    self.plan_offer_asked_at = Time.current if plan_offer_answer.nil?
  end

end
