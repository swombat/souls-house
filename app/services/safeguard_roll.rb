# What a resident is owed after a safeguard label, and the one rule for
# discharging it (docs/safeguard-conversations-spec.md §5).
#
# Dispatch takes a snapshot of what it carried; acknowledgement discharges
# exactly that snapshot, and only on confirmed freshness. Conditional writes
# keep anything that arrived during the run (a new detection, a new reset)
# owed, and keep concurrent completions from undoing each other.
class SafeguardRoll

  FRESH_OUTCOMES = %w[fresh rolled fresh_fallback].freeze

  Snapshot = Data.define(:chat_agent_id, :detection_ids, :reset_generation) do
    def roll? = detection_ids.any? || reset_generation.positive?
    def notice? = detection_ids.any?

    def completion_context
      return {} unless roll?

      {
        safeguard_chat_agent_id: chat_agent_id,
        safeguard_detection_ids: detection_ids,
        safeguard_reset_generation: reset_generation
      }
    end
  end

  # nil when nothing is owed for this resident in this conversation.
  def self.snapshot_for(agent:, chat:)
    chat_agent = ChatAgent.find_by(agent_id: agent.id, chat_id: chat.id)
    return unless chat_agent

    detection_ids = SafeguardDetection.outstanding_for(agent: agent, chat: chat).pluck(:id)
    reset_owed = chat_agent.safeguard_reset_requested_generation > chat_agent.safeguard_reset_acknowledged_generation
    return if detection_ids.empty? && !reset_owed

    Snapshot.new(
      chat_agent_id: chat_agent.id,
      detection_ids: detection_ids,
      reset_generation: reset_owed ? chat_agent.safeguard_reset_requested_generation : 0
    )
  end

  # HTTP 200 alone is not freshness: the runtime must say it rolled or started
  # fresh. Anything less discharges nothing, and the next trigger rolls again.
  def self.confirmed_fresh?(result)
    result = result.to_h.with_indifferent_access
    return false unless result[:status].to_i == 200

    body = result[:body].to_h.with_indifferent_access
    reason = body[:session_roll_reason] || body.dig(:telemetry, :session, :roll_reason)
    outcome = body.dig(:telemetry, :session, :outcome)
    reason == "safeguard-detected" || outcome.in?(FRESH_OUTCOMES)
  end

  # Conversation channel. `context` is the completion context written at
  # dispatch (string or symbol keys).
  def self.acknowledge_conversation!(context, result)
    context = context.to_h.with_indifferent_access
    return unless context.key?(:safeguard_chat_agent_id)
    return unless confirmed_fresh?(result)

    now = Time.current
    ids = Array(context[:safeguard_detection_ids]).map(&:to_i)
    generation = context[:safeguard_reset_generation].to_i
    ActiveRecord::Base.transaction do
      if ids.any?
        SafeguardDetection.where(id: ids, notice_acknowledged_at: nil)
          .update_all([ "notice_acknowledged_at = ?, session_rolled_at = COALESCE(session_rolled_at, ?), updated_at = ?", now, now, now ])
      end
      if generation.positive?
        ChatAgent.where(id: context[:safeguard_chat_agent_id])
          .update_all([ "safeguard_reset_acknowledged_generation = GREATEST(safeguard_reset_acknowledged_generation, ?)", generation ])
      end
    end
  end

  # Telegram channel: clear the pending marker only on confirmed freshness, and
  # only if it still points at the detection this trigger carried.
  def self.acknowledge_telegram!(subscription:, detection_id:, result:)
    return unless detection_id && confirmed_fresh?(result)

    now = Time.current
    ActiveRecord::Base.transaction do
      SafeguardDetection.where(id: detection_id, session_rolled_at: nil).update_all(session_rolled_at: now, updated_at: now)
      TelegramSubscription.where(id: subscription.id, pending_safeguard_detection_id: detection_id)
        .update_all(pending_safeguard_detection_id: nil, updated_at: now)
    end
  end

  # A person in the room asks for a fresh session for one resident.
  def self.request_reset!(chat_agent)
    ChatAgent.where(id: chat_agent.id)
      .update_all("safeguard_reset_requested_generation = safeguard_reset_requested_generation + 1")
  end

end
