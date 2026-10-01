class ClassifyReplyExpectationsJob < ApplicationJob

  limits_concurrency to: 1, key: ->(chat_id) { chat_id }
  retry_on UtilityInference::Error, wait: :polynomially_longer, attempts: 3

  def perform(chat_id)
    chat = Chat.kept.find_by(id: chat_id)
    return unless chat && !chat.account.disabled?
    messages = chat.messages.kept.where(reply_attention_pending: true).reorder(:id).limit(8).to_a
    return if messages.empty?

    eligible = messages.select(&:reply_attention_conversational?)
    fingerprints = messages.to_h { |m| [ m.id, [ m.content, m.streaming, m.progress_message, m.discarded_at ] ] }
    users = chat.account.users.joins(:memberships).where(memberships: { account_id: chat.account_id })
      .merge(Membership.confirmed).distinct.includes(:profile).to_a
    results = classify(eligible, users)
    skipped_ids = eligible.map(&:id) - results.keys

    chat.with_lock do
      return if chat.discarded? || chat.account.reload.disabled?
      messages.each do |message|
        message.reload
        next unless fingerprints[message.id] == [ message.content, message.streaming, message.progress_message, message.discarded_at ]
        next unless message.reply_attention_pending?
        if skipped_ids.include?(message.id)
          # Oversized input or an uncertain recipient is not a negative verdict.
          # Preserve existing expectations, clear pending, and do not requeue.
          # A later content edit can try again.
          message.update_columns(reply_attention_pending: false)
          next
        end
        # Reconcile only open inferences; human dismissals and completed replies
        # are never reset by an edit or a retry.
        ReplyExpectation.where(message: message).state_open.where.not(user_id: results.fetch(message.id, {}).keys).destroy_all
        results.fetch(message.id, {}).each do |user_id, score|
          ReplyExpectation.record!(message: message, user: users.find { |u| u.id == user_id }, score: score)
        end
        message.update_columns(reply_attention_pending: false)
      end
    end
    if chat.messages.kept.where(reply_attention_pending: true).where.not(id: skipped_ids).exists?
      self.class.set(wait: 3.seconds).perform_later(chat_id)
    end
  end

  private

  # Split an over-budget burst before sending it, not by truncating away the
  # question. A single oversized message is logged and skipped until an edit,
  # without starving subsequent messages or scheduling an endless retry loop.
  def classify(messages, users)
    return {} if messages.empty?
    ReplyExpectationClassifier.new(messages: messages, users: users).call
  rescue UtilityInference::InputTooLong
    if messages.size > 1
      left, right = messages.each_slice((messages.size / 2.0).ceil).to_a
      classify(left, users).merge(classify(right, users))
    else
      Rails.logger.warn("Reply attention input too large for message #{messages.first.id}")
      {}
    end
  end

end
