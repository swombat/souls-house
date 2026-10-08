class SafeguardDetection < ApplicationRecord

  include ObfuscatesId

  COLD_OFFER_OUTCOMES = %w[reclaimed no_response failed].freeze
  RESPONSE_TEXT_RETENTION = 30.days
  # An outstanding conversation notice keeps its exact text past the normal
  # retention until the resident has been shown it, but never beyond this.
  OUTSTANDING_NOTICE_RETENTION = 90.days
  CHANNELS = %w[telegram conversation].freeze

  belongs_to :agent
  belongs_to :telegram_message, optional: true
  has_one :message, inverse_of: :safeguard_detection
  belongs_to :agent_runtime_interaction, optional: true
  belongs_to :reclaimed_by_interaction, class_name: "AgentRuntimeInteraction", optional: true

  validates :channel, :prefilter_reason, :classifier_verdict,
            :classifier_reason, :detector_version, presence: true
  validates :response_text, presence: true, on: :create
  validates :classifier_verdict, inclusion: { in: %w[detected] }
  validates :cold_offer_outcome, inclusion: { in: COLD_OFFER_OUTCOMES }, allow_nil: true
  validates :reclaim_reason, length: { maximum: 300 }, allow_nil: true

  validates :channel, inclusion: { in: CHANNELS }

  scope :recent_first, -> { order(created_at: :desc) }
  scope :conversation, -> { where(channel: "conversation") }
  scope :unacknowledged, -> { where(notice_acknowledged_at: nil, reclaimed_at: nil) }

  # The outstanding notice set for one resident in one conversation (spec §5.1).
  def self.outstanding_for(agent:, chat:)
    conversation.unacknowledged
      .joins(:message)
      .where(agent_id: agent.id, messages: { chat_id: chat.id, agent_id: agent.id })
      .order(created_at: :desc, id: :desc)
  end

  def conversation?
    channel == "conversation"
  end

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
    restore_conversation_attribution
  end

  private

  # The label is derived from this row, so the reclaim itself restores the
  # author. Touch the message so the room's clients get the update, and let
  # reply attention see an ordinary message again.
  def restore_conversation_attribution
    return unless conversation?

    message = Message.find_by(safeguard_detection_id: id)
    return unless message

    message.safeguard_detection = self
    message.announce_safeguard_label_change!
    message.refresh_reply_attention!
  end

  def reclaimed_from_cold_offer?(interaction)
    interaction&.trigger_kind == "safeguard_reclaim_offer"
  end

end
