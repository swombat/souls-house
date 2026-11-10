# Whether a resident whose subscription allowance has run out may answer on a
# paid fallback model (#690). Off by default: only the account owner can turn
# it on, naming the model and a spending cap per period. Approving the feature
# turns it on for no one.
#
# The payer is the account's own key, never Account#ai_api_key (which falls
# back to the house's keys) and never the house's inference key.
class ResidentFallbackPolicy < ApplicationRecord

  CAP_PERIODS = %w[week month].freeze
  PAYERS = %w[openrouter].freeze
  MAX_CAP_USD = 10_000

  belongs_to :agent
  belongs_to :enabled_by_user, class_name: "User", optional: true

  validates :cap_period, inclusion: { in: CAP_PERIODS }
  validates :payer, inclusion: { in: PAYERS }
  validates :cap_usd, numericality: { greater_than: 0, less_than_or_equal_to: MAX_CAP_USD }, allow_nil: true
  validate :enabled_policy_is_complete

  def model_config = ResidentFallback::Models.find(model_id)

  def model_label = model_id && ResidentFallback::Models.label(model_id)

  def payer_name = { "openrouter" => "OpenRouter" }.fetch(payer)

  # The account's own key for the payer. Never a house key.
  def payer_key
    key = agent.account.public_send("#{payer}_api_key")
    key if key.present? && !key.start_with?("<")
  end

  # The cap period containing `time`, in UTC: Monday 00:00 for a week, the
  # 1st at 00:00 for a month.
  def period_start(time = Time.current)
    time = time.utc
    cap_period == "week" ? time.beginning_of_week(:monday) : time.beginning_of_month
  end

  def period_end(time = Time.current)
    period_start(time) + (cap_period == "week" ? 1.week : 1.month)
  end

  # What this period has committed against the cap: settled calls at their
  # reported charge, pending and unresolved calls at their full reservation,
  # calls refused before they were sent at nothing.
  def committed_usd(time = Time.current)
    ResidentFallbackCall.committed_usd(agent_id: agent_id, period_start: period_start(time))
  end

  def remaining_usd(time = Time.current)
    return BigDecimal("0") unless cap_usd

    [ cap_usd - committed_usd(time), BigDecimal("0") ].max
  end

  private

  def enabled_policy_is_complete
    return unless enabled?

    errors.add(:model_id, "must be chosen to turn fallback on") if model_id.blank?
    errors.add(:model_id, "is not a model the fallback can use") if model_id.present? && model_config.nil?
    errors.add(:cap_usd, "must be set to turn fallback on") if cap_usd.blank?
    errors.add(:enabled_by_user, "must be recorded to turn fallback on") if enabled_by_user_id.blank?
  end

end
