# A request for a resident to respond that arrived while that resident was
# already responding in the same room: a knock from a sibling asking for a
# review, the agent button, or a message to a room's only resident.
#
# Before this existed the request was refused with "already responding", and
# whoever asked had to notice and try again later. The usual result was a
# review sitting unread while its addressee finished up and said it was
# waiting for that review.
#
# Now the request is kept. Later requests for the same resident in the same
# room coalesce into the one open row. When the busy run finishes,
# PendingWakeJob releases it as one ordinary run, which sees everything posted
# since its previous run through the usual transcript delta, or drops it with
# a reason. A wake never carries more authority than the trigger that queued
# it: a paused resident is not woken, and expired requests lapse.
class PendingWake < ApplicationRecord

  EXPIRY = 6.hours

  belongs_to :chat
  belongs_to :agent
  belongs_to :released_interaction, class_name: "AgentRuntimeInteraction", optional: true

  scope :open, -> { where(released_at: nil, dropped_at: nil) }

  # Record (or coalesce into) the open wake. The caller holds the chat lock,
  # and so does release!, which is what keeps a run that finishes between the
  # busy check and this write from orphaning the wake.
  def self.queue!(chat:, agent:, requested_by:)
    now = Time.current
    wake = open.find_by(chat: chat, agent: agent)
    if wake
      wake.update!(requests_count: wake.requests_count + 1, last_requested_at: now, requested_by: requested_by)
      wake
    else
      create!(chat: chat, agent: agent, requested_by: requested_by, first_requested_at: now, last_requested_at: now)
    end
  end

  # Release the open wake for this resident in this room, if it is due.
  # Returns the wake (released or dropped), or nil when there is nothing to do
  # yet. Still busy is "not yet", not a drop: the run that is busy now will
  # call this again when it finishes.
  def self.release!(chat:, agent:)
    chat.with_lock do
      wake = open.find_by(chat: chat, agent: agent)
      next nil unless wake
      next nil if chat.agent_response_active?(agent)

      reason = wake.lapse_reason
      next wake.drop!(reason) if reason

      begin
        result = chat.trigger_agent_response!(agent)
      rescue Agent::RuntimeAvailability::Unavailable => error
        next wake.drop!("unavailable:#{error.code}")
      rescue Chat::AlreadyResponding
        next nil
      rescue ArgumentError
        next wake.drop!("not_invokable")
      end

      wake.update!(released_at: Time.current,
                   released_interaction: result.is_a?(AgentRuntimeInteraction) ? result : nil)
      wake
    end
  end

  # Why this wake should not run, or nil. Checked at release, under the lock.
  def lapse_reason
    return "expired" if last_requested_at < EXPIRY.ago
    return "not_respondable" unless chat.respondable? && chat.manual_responses? && !chat.account.disabled?
    return "not_in_room" unless chat.agents.exists?(agent.id)
    return "paused" if agent.paused?
    return "nothing_new" unless unseen_messages?

    nil
  end

  # Whether anyone else has posted since the last message a run of this
  # resident here was shown. If the run that just finished already saw the
  # message behind this knock, waking again would answer it twice. The cursor
  # counts only runs that reached the runtime, as the transcript delta does;
  # with none, assume there is something to see.
  def unseen_messages?
    cursor = chat.agent_runtime_interactions
      .where(agent: agent, trigger_kind: "conversation")
      .where(transport_status: 200...300, runtime_status: "ok")
      .maximum(:last_included_message_id)
    scope = chat.messages.kept.where("agent_id IS NULL OR agent_id <> ?", agent.id)
    scope = scope.where("id > ?", cursor) if cursor
    scope.exists?
  end

  def drop!(reason)
    update!(dropped_at: Time.current, drop_reason: reason)
    self
  end

  # One line for the released run's prompt, so the resident knows why it woke.
  def prompt_note
    count = requests_count == 1 ? "A request" : "#{requests_count} requests"
    "#{count} for you to respond arrived here while you were already responding " \
      "(most recently from #{requested_by}, at #{last_requested_at.utc.iso8601}). " \
      "They were held until that run finished. Everything posted since your previous run is in the transcript below."
  end

end
