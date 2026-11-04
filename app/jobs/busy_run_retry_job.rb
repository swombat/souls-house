# A person's request that reached the resident while its previous run was
# still letting go comes back 409 already_running and is recorded "busy". The
# house had already shown that previous run as finished, so the person tapped,
# and nothing asked again: the request was simply gone, and they had to wait
# and tap a second time (YDbggj, 4 Nov 2026).
#
# A resident's handoff and a commitment retry their own busy runs
# (MessageHandoff#retry_after_busy!, Commitment#follow_run!). This does the
# same for a run a person asked for: a few seconds later it wakes the
# resident again, once, as an ordinary run that reads everything posted since
# its last one. It stands down if any later run of the resident here exists
# (that run reads the same transcript, and a later busy one carries its own
# retry), and gives up after MAX_ATTEMPTS busy answers in a row.
class BusyRunRetryJob < ApplicationJob

  DELAY = 5.seconds
  MAX_ATTEMPTS = 4
  WINDOW = 5.minutes

  queue_as :default
  limits_concurrency to: 1, key: ->(interaction_id) { "busy-run-retry-#{interaction_id}" }

  def self.retry?(interaction)
    interaction.trigger_kind == "conversation" && interaction.chat_id.present? &&
      interaction.execution_state == "busy" && Array(interaction.wake_source_kinds).include?("human") &&
      !Commitment.exists?(wake_interaction_id: interaction.id)
  end

  def perform(interaction_id)
    busy = AgentRuntimeInteraction.find_by(id: interaction_id)
    return unless busy && self.class.retry?(busy)

    chat = busy.chat
    agent = busy.agent
    chat.with_lock do
      return if superseded?(busy)
      return if consecutive_busy(busy) > MAX_ATTEMPTS
      return unless chat.respondable? && chat.manual_responses? && chat.agents.exists?(agent.id)
      return if agent.reload.paused?

      begin
        chat.trigger_agent_response!(agent, wake_source_kinds: busy.wake_source_kinds)
      rescue Chat::AlreadyResponding
        # The run still letting go is now visible as active again, or another
        # run has started; either way its end releases what is waiting, and a
        # run started now reads the person's message.
        nil
      rescue Agent::RuntimeAvailability::Unavailable, ArgumentError
        nil
      end
    end
  end

  private

  # A later run of this resident in this room reads everything the busy one
  # would have; a later busy run has a retry of its own.
  def superseded?(busy)
    AgentRuntimeInteraction.where(chat_id: busy.chat_id, agent_id: busy.agent_id, trigger_kind: "conversation")
      .where("id > ?", busy.id).exists?
  end

  # How many busy answers in a row this resident has given here, ending with
  # this one, within the window.
  def consecutive_busy(busy)
    recent = AgentRuntimeInteraction.where(chat_id: busy.chat_id, agent_id: busy.agent_id, trigger_kind: "conversation")
      .where("id <= ? AND created_at > ?", busy.id, WINDOW.ago).order(id: :desc).pluck(:execution_state)
    recent.take_while { |state| state == "busy" }.size
  end

end
