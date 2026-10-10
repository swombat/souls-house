# A resident's message asking another resident in the room to act, and the
# receipt for it: one row per (message, recipient).
#
# Before this, a resident's post woke nobody. "@Mira, ready for review" was a
# sentence in the room; only a separate agent_trigger call, made by the same
# run after posting, reached Mira, and that call was what got forgotten or
# lost when the run ended. Now the post itself carries the request. An
# explicit @Name tag of another resident in the room (read as DirectReplyMentions
# reads a person's tag, so quotes and code ring no one's bell), or the post's
# recipient_agent_ids, writes a row here in the transaction that saves the
# message. MessageHandoffJob then knocks for it after the commit, through the
# same path agent_trigger uses: the recipient is woken now, or, if already
# responding here, held as a PendingWake with this message as its source.
#
# The receipt says whether the message reached the recipient, not whether
# they replied:
#
# - queued (pending, triggered): accepted, or a run reserved, and that run
#   has not yet read the transcript;
# - held: the recipient was busy; the request waits for that run to end;
# - delivered: a run of the recipient's that read the transcript included
#   this message (the same cursor PendingWake#unseen_messages? reads). A run
#   that started before the message and never re-read has not delivered it;
# - blocked, with a reason: it will not be delivered by this request.
#
# Delivered wins: a request blocked or held whose message a later run reads
# becomes delivered. Silence after delivered is the recipient's choice.
#
# Loop guard: at most the account's resident_handoff_cap handoffs per room
# between human messages. Past it the request is blocked (loop_cap) and the
# room is told once, so it never stops silently.
class MessageHandoff < ApplicationRecord

  STATUSES = %w[pending triggered held delivered blocked].freeze
  SOURCES = %w[tag field].freeze
  # Unfinished requests: not yet delivered and not given up on.
  OPEN_STATUSES = %w[pending triggered held].freeze
  # A request whose job never ran (a lost enqueue) is recorded, not retried,
  # as for a human's mention (MessageDispatch::EXPIRY, consultation BjAPDe).
  EXPIRY = 10.minutes
  LOOP_CAP_REASON = "loop_cap".freeze
  # The account set its cap to 0.
  HANDOFFS_OFF_REASON = "handoffs_off".freeze

  belongs_to :message
  belongs_to :chat
  belongs_to :requester_agent, class_name: "Agent", optional: true
  belongs_to :recipient_agent, class_name: "Agent"
  belongs_to :runtime_interaction, class_name: "AgentRuntimeInteraction", optional: true
  belongs_to :pending_wake, optional: true

  validates :status, inclusion: { in: STATUSES }
  validates :source, inclusion: { in: SOURCES }

  # The receipt under the message is live: whoever has the room open sees it
  # move. Not a touch, which would reorder the room in every list.
  after_commit -> { message.broadcast_handoff_receipts }, on: :update, if: :saved_change_to_status?

  scope :undelivered, -> { where.not(status: "delivered") }
  scope :open_requests, -> { where(status: OPEN_STATUSES) }

  # The residents a resident's message hands off to, in a stable order:
  # tagged ones, then any named in recipient_agent_ids. Never the author.
  def self.recipient_ids_for(message, explicit_ids: [])
    users = message.chat.account.users.joins(:memberships)
      .where(memberships: { account_id: message.chat.account_id }).merge(Membership.confirmed)
      .distinct.includes(:profile).to_a
    tagged = DirectReplyMentions.agent_ids(message: message, users: users)
    sources = tagged.index_with { "tag" }
    explicit_ids.each { |id| sources[id] ||= "field" }
    sources.except(message.agent_id)
  end

  # Written in the transaction that saves the message, which holds the chat
  # row lock (Message#record_chat_message_time), so the loop count is
  # serialized with every other post in the room. Returns the rows written.
  def self.accept!(message:, explicit_ids: [])
    chat = message.chat
    recipients = recipient_ids_for(message, explicit_ids: explicit_ids)
    return [] if recipients.empty?

    chat.lock!
    cap = chat.account.resident_handoff_cap
    counted = since_last_human_message(chat)
      .where("reason IS NULL OR reason NOT IN (?)", [ LOOP_CAP_REASON, HANDOFFS_OFF_REASON ]).count
    capped = []
    handoffs = recipients.map do |recipient_id, source|
      handoff = new(message: message, chat: chat, requester_agent_id: message.agent_id,
                    recipient_agent_id: recipient_id, source: source)
      if cap.zero?
        handoff.assign_attributes(status: "blocked", reason: HANDOFFS_OFF_REASON)
      elsif counted >= cap
        handoff.assign_attributes(status: "blocked", reason: LOOP_CAP_REASON)
        capped << handoff
      else
        counted += 1
      end
      handoff.save!
      handoff
    end
    announce_loop_cap!(chat, message, capped, cap) if capped.any?
    handoffs
  end

  # Handoffs written since the room's last message from a person.
  def self.since_last_human_message(chat)
    last_human_id = chat.messages.where(role: "user").where.not(user_id: nil).maximum(:id)
    scope = where(chat: chat)
    last_human_id ? scope.where("message_id > ?", last_human_id) : scope
  end

  # Said once per run of resident handoffs, in the room, as the house.
  def self.announce_loop_cap!(chat, message, capped, cap)
    already = since_last_human_message(chat).where(reason: LOOP_CAP_REASON).where.not(id: capped.map(&:id)).exists?
    return if already

    names = capped.map { |handoff| handoff.recipient_agent.name }.to_sentence
    chat.messages.create!(
      role: "system",
      content: "Residents have handed off to each other #{cap} times here since the last message from a person, " \
        "so #{message.author_name}'s message did not wake #{names}. " \
        "Resident handoffs in this conversation resume after someone posts."
    )
  end

  # Bring every undelivered request for this resident in this room up to
  # date: delivered when a run has read the message, blocked when the run
  # that was to read it ended without doing so or its held wake was dropped,
  # triggered when its held wake was released. Called after each commit that
  # can change that (MessageHandoffSyncJob).
  def self.sync!(chat:, agent:)
    cursor = chat.agent_transcript_cursor(agent)
    where(chat: chat, recipient_agent: agent).undelivered.includes(:runtime_interaction, :pending_wake).find_each do |handoff|
      handoff.sync!(cursor)
    end
  end

  def self.enqueue_sync(chat_id:, agent_id:)
    return unless where(chat_id: chat_id, recipient_agent_id: agent_id).undelivered.exists?

    MessageHandoffSyncJob.perform_later(chat_id, agent_id)
  rescue StandardError => e
    Rails.logger.warn "[MessageHandoff] sync enqueue failed for chat #{chat_id}, agent #{agent_id}: #{e.class}: #{e.message}"
  end

  # The job's work: knock for this request once. Idempotent under the chat
  # lock; anything but a pending request returns without effect.
  def dispatch!
    chat.with_lock do
      reload
      next unless pending?
      next deliver! if delivered_by?(chat.agent_transcript_cursor(recipient_agent))

      reason = blocked_reason
      next block!(reason) if reason

      begin
        result = chat.trigger_agent_response!(recipient_agent)
        update!(status: "triggered", runtime_interaction: result.is_a?(AgentRuntimeInteraction) ? result : nil)
      rescue Chat::AlreadyResponding
        wake = PendingWake.queue!(chat: chat, agent: recipient_agent, requested_by: "#{requester_label}'s message", message: message)
        update!(status: "held", pending_wake: wake)
      rescue Agent::RuntimeAvailability::Unavailable => error
        block!("unavailable:#{error.code}")
      rescue ArgumentError
        block!("not_invokable")
      end
    end
  end

  def sync!(cursor)
    return deliver! if delivered_by?(cursor)

    case status
    when "held"
      if pending_wake.nil?
        block!("wake_lost")
      elsif pending_wake.dropped_at
        block!(pending_wake.drop_reason.to_s.delete_prefix("claim_refused:").presence || "dropped")
      elsif pending_wake.released_at
        update!(status: "triggered", runtime_interaction: pending_wake.released_interaction)
      end
    when "triggered"
      run = runtime_interaction
      block!(run.execution_state.presence ? "run_#{run.execution_state}" : "run_ended") if run&.finished_at
    end
  end

  # The sweeper's: a request whose job never came is recorded as such.
  def settle_lapsed!
    with_lock { block!("not_started_in_time") if pending? && created_at <= EXPIRY.ago }
  end

  def pending? = status == "pending"
  def delivered? = status == "delivered"
  def blocked? = status == "blocked"

  # Open: the recipient has not yet seen it and something is still on its way.
  def open_request?
    case status
    when "pending", "held" then true
    when "triggered" then runtime_interaction.nil? || runtime_interaction.finished_at.nil?
    else false
    end
  end

  # What the receipt says: queued, held, delivered or blocked.
  def receipt_state
    case status
    when "pending", "triggered" then "queued"
    else status
    end
  end

  def as_receipt_json
    {
      recipient_id: recipient_agent.to_param,
      recipient_name: recipient_agent.name,
      source: source,
      state: receipt_state,
      reason: reason,
      delivered_at: delivered_at&.iso8601
    }
  end

  private

  def delivered_by?(cursor)
    cursor.present? && message_id <= cursor
  end

  def deliver!
    update!(status: "delivered", reason: nil, delivered_at: Time.current)
  end

  def block!(reason)
    update!(status: "blocked", reason: reason)
  end

  def requester_label
    requester_agent&.name || message.author_name
  end

  # Why this request should not wake its recipient now, or nil. The author's
  # authority is checked as a knock's is: still in the room.
  def blocked_reason
    return "not_started_in_time" if created_at <= EXPIRY.ago
    return "discarded" if message.reload.discarded?
    return "conversation_unavailable" unless chat.respondable? && chat.manual_responses? && !chat.account.disabled?
    return "author_not_in_room" unless requester_agent && chat.agents.exists?(requester_agent.id)
    return "not_in_room" unless chat.agents.exists?(recipient_agent.id)
    return "paused" if recipient_agent.reload.paused?
    return "unavailable" unless recipient_agent.eligible_for_conversation?

    nil
  end

end
