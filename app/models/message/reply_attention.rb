module Message::ReplyAttention

  extend ActiveSupport::Concern

  included do
    before_save :mark_reply_attention_pending, if: -> { new_record? || will_save_change_to_content? || will_save_change_to_streaming? || will_save_change_to_progress_message? || will_save_change_to_role? }
    after_create :close_reply_expectations
    after_save :record_direct_reply_mentions, if: :reply_attention_content_changed?
    after_save_commit :enqueue_reply_attention, if: :reply_attention_content_changed?
    after_save_commit :refresh_reply_attention_visibility, if: :saved_change_to_discarded_at?
  end

  # A labelled safeguard script asks no one for a reply on the resident's behalf.
  def reply_attention_conversational?
    role.in?(%w[user assistant]) && content.present? && !streaming? && !progress_message? && kept? &&
      !safeguard_labelled?
  end

  # Re-run the attention bookkeeping when conversational status changed
  # without a content change (a reclaimed safeguard label).
  def refresh_reply_attention!
    update!(reply_attention_pending: reply_attention_conversational?)
    record_direct_reply_mentions
    enqueue_reply_attention
  end

  private

  def reply_attention_content_changed?
    saved_change_to_content? || saved_change_to_streaming? || saved_change_to_progress_message? || saved_change_to_role?
  end

  def mark_reply_attention_pending
    self.reply_attention_pending = reply_attention_conversational?
  end

  def close_reply_expectations
    ReplyExpectation.close_for_reply!(self)
  end

  # Revisioned already holds the chat row lock in this save transaction. Tags
  # reach the existing attention stream even when inference or its queue is down.
  def record_direct_reply_mentions
    return if chat.discarded? || chat.account.disabled?

    users = chat.account.users.joins(:memberships)
      .where(memberships: { account_id: chat.account_id }).merge(Membership.confirmed)
      .distinct.includes(:profile).to_a
    ids = reply_attention_conversational? ? DirectReplyMentions.call(message: self, users: users) : []
    ReplyExpectation.where(message: self, classifier_version: ReplyExpectation::DIRECT_MENTION_VERSION)
      .state_open.where.not(user_id: ids).destroy_all
    users.select { |recipient| ids.include?(recipient.id) }.each do |recipient|
      ReplyExpectation.record!(message: self, user: recipient, score: 1.0,
        classifier_version: ReplyExpectation::DIRECT_MENTION_VERSION)
    end
  end

  def enqueue_reply_attention
    return unless reply_attention_pending?
    ClassifyReplyExpectationsJob.set(wait: 3.seconds).perform_later(chat_id)
  rescue StandardError => error
    # Sending succeeded. Keep pending state for the next chat job rather than
    # turn an optional classifier queue outage into an apparent failed send.
    Rails.logger.warn("Reply attention enqueue failed for message #{id}: #{error.class}")
  end

  def refresh_reply_attention_visibility
    ReplyExpectation.where(message_id: id).distinct.pluck(:user_id).each { |uid| ReplyExpectation.refresh_for(uid) }
  end

end
