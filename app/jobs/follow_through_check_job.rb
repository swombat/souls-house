# Runs a minute after a resident's conversation run ends (see
# AgentRuntimeInteraction#enqueue_follow_through_check). The supervisor
# enqueues it, not the resident, so a run that failed or ran out of budget
# mid-promise is checked like any other.
class FollowThroughCheckJob < ApplicationJob

  DELAY = 60.seconds
  DEFER_STEP = 60.seconds
  DEFER_LIMIT = 30

  queue_as :default
  limits_concurrency to: 1, key: ->(interaction_id, *) { "follow-through-#{interaction_id}" }
  retry_on UtilityInference::InvalidResponse, wait: :polynomially_longer, attempts: 3
  discard_on UtilityInference::MissingCredentials

  def perform(interaction_id, deferrals: 0)
    interaction = AgentRuntimeInteraction.includes(:agent, :chat).find_by(id: interaction_id)
    return unless interaction && FollowThroughCheck.checkable?(interaction)
    return if interaction.follow_through_checked_at?

    chat, agent = interaction.chat, interaction.agent
    return unless chat.respondable? && chat.manual_responses? && !chat.account.disabled?
    return unless agent.active? && chat.agents.exists?(agent.id)

    # Busy in this room: wait rather than discard. Busy elsewhere doesn't count.
    return defer(interaction_id, deferrals) if chat.agent_response_active?(agent)
    # A later run of the same resident here already saw this run's messages
    # and is checked on its own; one verdict per stretch of work is enough.
    return if later_run_here?(interaction)

    check = FollowThroughCheck.new(interaction)
    verdict = check.call
    claimed = AgentRuntimeInteraction.where(id: interaction.id, follow_through_checked_at: nil)
      .update_all(follow_through_checked_at: Time.current)
    return unless claimed == 1 && verdict == :unfinished

    if interaction.follow_through_of_id
      chat.messages.create!(role: "user", content: check.unresolved_notice)
    else
      nudge!(interaction, check, deferrals)
    end
  end

  private

  def defer(interaction_id, deferrals)
    return if deferrals >= DEFER_LIMIT

    self.class.set(wait: DEFER_STEP).perform_later(interaction_id, deferrals: deferrals + 1)
  end

  def later_run_here?(interaction)
    interaction.chat.agent_runtime_interactions
      .where(agent_id: interaction.agent_id, trigger_kind: "conversation")
      .where.not(id: interaction.id).where("started_at > ?", interaction.started_at)
      .where("execution_state IS NULL OR execution_state NOT IN ('cancelled', 'busy')")
      .exists?
  end

  # The notice and the reservation commit together, so the room never shows
  # a wake that didn't happen. The unique index makes a second nudge for the
  # same run impossible, whatever retries or races do.
  def nudge!(interaction, check, deferrals)
    chat = interaction.chat
    # Only a reserved run can carry the follow-through mark through to the
    # runtime, so without live activity there is no nudge to send.
    return unless AgentRuntimeInteraction.live_activity_enabled?

    chat.transaction do
      chat.messages.create!(role: "user", content: check.nudge_notice)
      AgentRuntimeInteraction.reserve!(agent: interaction.agent, chat: chat, enqueue: true, follow_through_of: interaction)
    end
  rescue Chat::AlreadyResponding
    AgentRuntimeInteraction.where(id: interaction.id).update_all(follow_through_checked_at: nil)
    defer(interaction.id, deferrals)
  rescue ActiveRecord::RecordNotUnique
    nil # Already nudged for this run.
  rescue Agent::RuntimeAvailability::Unavailable, ArgumentError => error
    Rails.logger.info("Follow-through nudge for interaction #{interaction.id} not sent: #{error.class}")
  end

end
