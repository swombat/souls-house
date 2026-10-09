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
# a reason. A wake never carries more authority than what queued it: it
# stands only while one of its sources does (PendingWakeSource), a paused
# resident is not woken, and expired requests lapse. The same checks run
# again when the released run claims, so a pause, a discard or a removal
# while it waits in the queue still stops it.
class PendingWake < ApplicationRecord

  EXPIRY = 6.hours

  belongs_to :chat
  belongs_to :agent
  belongs_to :released_interaction, class_name: "AgentRuntimeInteraction", optional: true
  has_many :sources, class_name: "PendingWakeSource", dependent: :delete_all

  scope :open, -> { where(released_at: nil, dropped_at: nil) }

  # Record (or coalesce into) the open wake, with what asked for it, and
  # attempt a release once it commits. The caller holds the chat lock across
  # its busy check and this write. A source is one of: message: (a human message that named or
  # addressed the resident), requester_agent: (a sibling's knock) or user:
  # (a person's button or API call).
  def self.queue!(chat:, agent:, requested_by:, message: nil, user: nil, requester_agent: nil)
    now = Time.current
    wake = open.find_by(chat: chat, agent: agent)
    if wake
      wake.update!(requests_count: wake.requests_count + 1, last_requested_at: now, requested_by: requested_by)
    else
      wake = create!(chat: chat, agent: agent, requested_by: requested_by, first_requested_at: now, last_requested_at: now)
    end
    if message
      wake.sources.create!(kind: "message", message: message, user: message.user)
    else
      wake.sources.create!(kind: "trigger", user: requester_agent ? nil : user, requester_agent: requester_agent)
    end
    # A run that ended while this transaction was open could not see the
    # wake; this job, after the commit, can. See PendingWakeJob for the rule.
    chat_id, agent_id = chat.id, agent.id
    ActiveRecord.after_all_transactions_commit { PendingWakeJob.perform_later(chat_id, agent_id) }
    wake
  end

  # Release the open wake for this resident in this room, if it is due.
  # Returns the wake (released or dropped), or nil when there is nothing to do
  # yet. Still busy is "not yet", not a drop: the run that is busy now will
  # call this again when it finishes. Seeing no wake is also "not yet" when a
  # queue! is still uncommitted; its own after-commit job covers that.
  def self.release!(chat:, agent:)
    transaction do
      # Uncached: a release earlier in the same unit of work may have seen no
      # wake, and the wake's own after-commit release must not reuse that.
      wake = uncached { open.find_by(chat: chat, agent: agent) }
      next nil unless wake

      # Lock what a withdrawal writes, in the order those writers take it, so
      # a discard, edit, pause or removal in flight is waited for and one
      # already committed is seen. See lock_revocation_rows!.
      wake.lock_revocation_rows!
      next nil unless wake.reload.released_at.nil? && wake.dropped_at.nil?
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

  # Row locks on everything a withdrawal of this wake writes, taken at
  # release and at claim (inside the caller's transaction), so the decision
  # and the withdrawal are serialized: a withdrawal that commits first is
  # seen, one in flight is waited for, and one that comes after lands after
  # the decision.
  #
  # Order matters. Writing a message touches its chat row, so the source
  # messages (discard, edit) come before the chat (archive, the room lock
  # queue! and reserve! hold). Then the account (disable), the resident
  # (pause), the requesters' memberships (removal) and room seats (a
  # knocking resident removed).
  def lock_revocation_rows!
    Message.where(id: sources.where.not(message_id: nil).select(:message_id)).order(:id).lock.load
    chat.lock!
    Account.where(id: chat.account_id).lock.load
    self.agent = Agent.lock.find(agent_id)
    user_ids = sources.where.not(user_id: nil).select(:user_id)
    Membership.where(account_id: chat.account_id, user_id: user_ids).order(:id).lock.load
    requester_ids = sources.where.not(requester_agent_id: nil).select(:requester_agent_id)
    ChatAgent.where(chat_id: chat_id, agent_id: [ agent_id, *requester_ids.pluck(:requester_agent_id) ]).order(:id).lock.load
  end

  # Why this wake should not run, or nil. Checked at release, under the lock.
  def lapse_reason
    return "expired" if last_requested_at < EXPIRY.ago
    return "not_respondable" unless chat.respondable? && chat.manual_responses? && !chat.account.disabled?
    return "not_in_room" unless chat.agents.exists?(agent.id)
    return "paused" if agent.paused?
    return "sources_withdrawn" unless standing_source?
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

  def standing_source?
    sources.includes(:message, :user, :requester_agent).any? { |source| source.standing?(chat) }
  end

  # Checked when the released run claims, under this row's lock: the run
  # starts only if the wake would still be released now. Pause, the room and
  # the sources can all change while the run waits in the queue, so the
  # rows those changes write are locked first (lock_revocation_rows!) and
  # stay locked until the claim commits.
  def claim_refusal_reason
    lock_revocation_rows!
    return "paused" if agent.paused?
    return "not_respondable" unless chat.respondable? && chat.manual_responses? && !chat.account.reload.disabled?
    return "not_in_room" unless chat.agents.exists?(agent.id)
    return "sources_withdrawn" unless standing_source?

    nil
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
