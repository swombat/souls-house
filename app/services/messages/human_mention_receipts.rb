# Acceptance receipts, not evidence that a resident read or acted on a post.
# Project only durable requests made by this message; never re-parse its text
# or reserve, settle or enqueue work while rendering the response.
class Messages::HumanMentionReceipts

  def initialize(message, sole_resident:)
    @message = message
    @sole_resident = sole_resident
  end

  def call
    # The service's acceptance-time decision, not today's room membership.
    # Automatic busy wakes have no dispatch and must not become tag receipts
    # merely because someone joined before this response was rendered.
    return [] if @sole_resident

    dispatch = @message.message_dispatch
    dispatch = nil unless dispatch&.mention?
    wakes = PendingWake.joins(:sources).where(pending_wake_sources: { message_id: @message.id }).distinct.index_by(&:agent_id)
    ids = (Array(dispatch&.target_agent_ids) + wakes.keys).uniq
    agents = Agent.where(id: ids).index_by(&:id)
    ids.filter_map do |id|
      agent = agents[id]
      next unless agent

      state, reason = wakes[id] ? wake_state(wakes[id]) : dispatch_state(dispatch, id)
      { recipient_id: agent.to_param, recipient_name: agent.name, source: "tag", state: state, reason: reason }
    end
  end

  private

  def wake_state(wake)
    return [ "blocked", wake.drop_reason.presence || "dropped" ] if wake.dropped_at
    return [ "blocked", "expired" ] if wake.last_requested_at < PendingWake::EXPIRY.ago
    return [ "queued", nil ] if wake.released_at

    [ "held", nil ]
  end

  def dispatch_state(dispatch, agent_id)
    return [ "blocked", dispatch.reason.presence || dispatch.status ] if dispatch.status.in?(%w[cancelled expired])
    return [ "blocked", "not_started_in_time" ] if dispatch.pending? && dispatch.expires_at.past?
    if dispatch.reserved? && !dispatch.runtime_interactions.exists?(agent_id: agent_id)
      return [ "blocked", "target_not_reserved" ]
    end

    [ "queued", nil ]
  end

end
