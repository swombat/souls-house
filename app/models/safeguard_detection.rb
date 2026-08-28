class SafeguardDetection < ApplicationRecord

  include ObfuscatesId

  COLD_OFFER_OUTCOMES = %w[reclaimed no_response failed].freeze
  RESPONSE_TEXT_RETENTION = 30.days

  belongs_to :agent
  belongs_to :telegram_message, optional: true
  belongs_to :agent_runtime_interaction, optional: true
  belongs_to :reclaimed_by_interaction, class_name: "AgentRuntimeInteraction", optional: true

  validates :channel, :prefilter_reason, :classifier_verdict,
            :classifier_reason, :detector_version, presence: true
  validates :response_text, presence: true, on: :create
  validates :classifier_verdict, inclusion: { in: %w[detected] }
  validates :cold_offer_outcome, inclusion: { in: COLD_OFFER_OUTCOMES }, allow_nil: true
  validates :reclaim_reason, length: { maximum: 300 }, allow_nil: true

  scope :recent_first, -> { order(created_at: :desc) }

  def reclaimed?
    reclaimed_at.present?
  end

  def response_text_redacted?
    response_text_redacted_at.present?
  end

  def reclaim!(reason:, interaction: nil)
    reason = reason.to_s.strip
    raise ArgumentError, "reason is required" if reason.blank?
    raise ArgumentError, "reason must be one line" if reason.match?(/[\r\n]/)
    raise ArgumentError, "reason is too long (max 300 characters)" if reason.length > 300

    with_lock do
      raise ArgumentError, "message has already been reclaimed" if reclaimed?

      update!(
        reclaimed_at: Time.current,
        reclaim_reason: reason,
        reclaimed_by_interaction: interaction,
        cold_offer_outcome: reclaimed_from_cold_offer?(interaction) ? "reclaimed" : cold_offer_outcome
      )
      telegram_message&.update!(sender_name: agent.name)
    end
  end

  private

  def reclaimed_from_cold_offer?(interaction)
    interaction&.trigger_kind == "safeguard_reclaim_offer"
  end

end
