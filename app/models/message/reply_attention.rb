module Message::ReplyAttention

  extend ActiveSupport::Concern

  included do
    before_save :mark_reply_attention_pending, if: -> { new_record? || will_save_change_to_content? || will_save_change_to_streaming? }
    after_create :close_reply_expectations
    after_save_commit :enqueue_reply_attention, if: :reply_attention_content_changed?
    after_save_commit :refresh_reply_attention_visibility, if: :saved_change_to_discarded_at?
  end

  def reply_attention_conversational?
    role.in?(%w[user assistant]) && content.present? && !streaming? && !progress_message? && kept?
  end

  private

  def reply_attention_content_changed?
    saved_change_to_content? || saved_change_to_streaming?
  end

  def mark_reply_attention_pending
    self.reply_attention_pending = reply_attention_conversational?
  end

  def close_reply_expectations
    ReplyExpectation.close_for_reply!(self)
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
