# A person's request that reached the resident while its previous run was
# still letting go comes back 409 already_running and is recorded "busy". The
# house had already shown that previous run as finished, so the person tapped,
# and nothing asked again: the request was simply gone, and they had to wait
# and tap a second time (YDbggj, 4 Nov 2026).
#
# A resident's handoff and a commitment retry their own busy runs
# (MessageHandoff#retry_after_busy!, Commitment#follow_run!). This hands a
# busy run a person asked for back to the queue it would have joined had the
# house known the resident was busy: a PendingWake, carrying the run's
# original sources, not just its provenance label (Mira, #781):
#
# - a run released from a wake: that wake's sources;
# - a run reserved for a message (MessageDispatch): the message;
# - a run a person reserved by tapping: that person (requested_by_user).
#
# The wake then decides as every held request does. Its sources must still
# stand at release and at claim (a discarded message, a removed member, a
# paused resident or a closed room stops it, before or after a run is
# reserved), and it is dropped as nothing_new only when a run that reached
# the runtime has read past everything posted, not because some later row
# exists. Requests coalesce into one open wake, so a handoff's own retry and
# this one never wake the resident twice for the same messages.
#
# Re-queued a few seconds later, so the run still letting go has gone; gives
# up after MAX_ATTEMPTS busy answers in a row inside WINDOW.
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
    return if consecutive_busy(busy) > MAX_ATTEMPTS

    chat = busy.chat
    agent = busy.agent
    requests = sources_of(busy)
    return if requests.empty?

    chat.with_lock do
      requests.each do |request|
        PendingWake.queue!(chat: chat, agent: agent, requested_by: request.delete(:requested_by), **request)
      end
    end
  end

  private

  # What gave the busy run its authority, as PendingWake.queue! arguments.
  # Standing is not judged here: the wake judges it, at release and at claim.
  def sources_of(busy)
    if (wake = busy.released_pending_wake)
      wake.sources.includes(:message, :user, :requester_agent).filter_map do |source|
        request = { requested_by: wake.requested_by, wake_source_kinds: source.wake_source_kinds.presence }
        if source.kind == "message"
          request.merge(message: source.message) if source.message
        elsif source.requester_agent || source.user
          request.merge(user: source.user, requester_agent: source.requester_agent)
        end
      end
    elsif (message = busy.message_dispatch&.message)
      [ { requested_by: "a message from #{message.user ? ResidentFacingName.for(message.user) : message.author_name}",
          message: message, wake_source_kinds: busy.wake_source_kinds.presence } ]
    elsif (user = busy.requested_by_user)
      [ { requested_by: ResidentFacingName.for(user), user: user, wake_source_kinds: busy.wake_source_kinds.presence } ]
    else
      []
    end
  end

  # How many busy answers in a row this resident has given here, ending with
  # this one, within the window.
  def consecutive_busy(busy)
    AgentRuntimeInteraction.where(chat_id: busy.chat_id, agent_id: busy.agent_id, trigger_kind: "conversation")
      .where("id <= ? AND created_at > ?", busy.id, WINDOW.ago).order(id: :desc).pluck(:execution_state)
      .take_while { |state| state == "busy" }.size
  end

end
