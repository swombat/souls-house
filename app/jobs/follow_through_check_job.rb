# Runs a minute after a resident's conversation run ends (see
# AgentRuntimeInteraction#enqueue_follow_through_check). The supervisor
# enqueues it, not the resident, so a run that failed or ran out of budget
# mid-promise is checked like any other.
class FollowThroughCheckJob < ApplicationJob

  class StaleEvidence < StandardError; end

  DELAY = 60.seconds
  DEFER_STEP = 60.seconds
  DEFER_LIMIT = 30
  UNKNOWN_GRACE = 10.minutes

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
    # Busy in this room, or a later run here that lost contact and may still
    # be working: wait rather than judge or discard. Other rooms don't count.
    # A later run that finished does not settle this one: the check still
    # judges this run's promise, with everything after it as evidence.
    return defer(interaction_id, deferrals) if chat.agent_response_active?(agent) || later_run_unsettled?(interaction)

    check = FollowThroughCheck.new(interaction)
    boundary = check.evidence_boundary
    verdict = check.call
    act!(interaction, check, verdict, boundary)
  rescue StaleEvidence, Chat::AlreadyResponding
    defer(interaction_id, deferrals)
  end

  private

  # The checked marker and its effect commit together under the room lock,
  # after confirming nothing new has happened since the evidence was read.
  # A failure anywhere rolls both back, so a retry acts again instead of
  # finding the run marked checked with nothing done.
  def act!(interaction, check, verdict, boundary)
    chat = interaction.chat
    chat.transaction do
      chat.lock!
      interaction.lock!
      next if interaction.follow_through_checked_at?
      raise StaleEvidence unless check.evidence_boundary == boundary

      if verdict == :unfinished
        if interaction.follow_through_of_id
          chat.messages.create!(role: "user", content: check.unresolved_notice)
        else
          nudge!(interaction, check)
        end
      end
      interaction.update_columns(follow_through_checked_at: Time.current)
    end
  rescue ActiveRecord::RecordNotUnique
    # This run already has its nudge; nothing more to do for it.
    AgentRuntimeInteraction.where(id: interaction.id).update_all(follow_through_checked_at: Time.current)
  end

  # One nudge per stretch of work: if a check of a nearby run has already
  # woken this resident here, a second wake would be the loop we're avoiding.
  def nudge!(interaction, check)
    return unless AgentRuntimeInteraction.live_activity_enabled?
    chat, agent = interaction.chat, interaction.agent
    # Paused means "don't wake me"; a nudge must not route around it.
    return if agent.paused? || !agent.eligible_for_conversation?
    return if chat.agent_runtime_interactions.where(agent: agent).where.not(follow_through_of_id: nil)
      .where("created_at > ?", interaction.started_at).exists?

    # Reserve first: if the resident can't be woken, no notice claims it was.
    AgentRuntimeInteraction.reserve!(agent: agent, chat: chat, enqueue: true, follow_through_of: interaction)
    chat.messages.create!(role: "user", content: check.nudge_notice)
  rescue Agent::RuntimeAvailability::Unavailable => error
    # Paused or unavailable: the check is done, and there is no one to wake.
    Rails.logger.info("Follow-through nudge for interaction #{interaction.id} not sent: #{error.class}")
  end

  def defer(interaction_id, deferrals)
    return if deferrals >= DEFER_LIMIT

    self.class.set(wait: DEFER_STEP).perform_later(interaction_id, deferrals: deferrals + 1)
  end

  def later_run_unsettled?(interaction)
    interaction.chat.agent_runtime_interactions
      .where(agent_id: interaction.agent_id, trigger_kind: "conversation", execution_state: "outcome_unknown")
      .where("started_at > ? AND finished_at > ?", interaction.started_at, UNKNOWN_GRACE.ago)
      .exists?
  end

end
