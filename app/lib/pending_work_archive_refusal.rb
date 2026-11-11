# Shared guard for archive paths that must not dismiss or silence owed work.
# Call under the chat's write lock, keeping it through archive!. Commitments
# are only read here: their own lock order is commitment → chat.
class PendingWorkArchiveRefusal

  def initialize(chat)
    @chat = chat
  end

  def call
    expectations = ReplyExpectation.joins(:message).state_open
      .where(messages: { chat_id: @chat.id, discarded_at: nil }).includes(:user, :message)
    # Scheduled ones made here, and ones already activated into this chat
    # whose wake is still held or retrying (a claim or retry checks
    # activation_chat.respondable?, so archiving would strand them).
    commitments = Commitment.scheduled.where(source_chat_id: @chat.id)
      .or(Commitment.wake_in_custody.where(activation_chat_id: @chat.id))
      .includes(:agent).order(:due_at)
    return nil if expectations.none? && commitments.none?

    {
      error: "This conversation still has something owed in it; archiving would dismiss or silence it. Answer, dismiss or cancel these first.",
      code: "conversation_has_pending_work",
      open_reply_expectations: expectations.map { |e|
        { message_id: e.message.to_param, awaiting: e.user&.display_name }
      },
      scheduled_commitments: commitments.map { |c|
        { id: c.to_param, resident: c.agent.name, due_at: c.due_at.iso8601, status: c.status, headline: c.headline }
      }
    }
  end

end
