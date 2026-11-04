# Successful execution is not delivery. Only this turn's accepted Telegram
# output counts, including media-only sends. Never infer a reason from stdout.
class TelegramTurnCompletionNotice

  def self.call(run, subscription)
    return unless run.trigger_kind == "telegram" && subscription.direct? &&
      subscription.agent_id == run.agent_id && subscription.to_param == run.conversation_obfuscated_id

    text = run.with_lock do
      return unless run.finished_at && run.runtime_status == "ok" &&
        run.transport_status.to_i.between?(200, 299) && run.runtime_returncode.to_i.zero?
      # Older runtime images cannot link helper delivery. Do not misreport
      # their real replies while Rails and residents roll out independently.
      return unless run.run_id.present? && run.response_body["telegram_delivery_run_id"] == run.run_id
      return if run.telegram_completion_notice_at || !subscription.deliverable?
      return if run.linked_telegram_messages.where(telegram_subscription: subscription).where.not(telegram_message_id: nil).exists?

      # A declared quiet with no explanation stays silent. With an explanation,
      # deliver the resident's words, explicitly attributed, not a house guess.
      return if run.quiet_reason_at && run.quiet_reason.blank?

      notice = if run.quiet_reason_at
        "souls.house: #{run.agent.name} chose not to reply. Their stated reason:\n#{run.quiet_reason}"
      else
        "souls.house: #{run.agent.name}'s turn finished without sending a reply."
      end
      # One attempt per turn, including an ambiguous/failed Telegram send.
      # Retrying work or blindly re-sending a notice could duplicate delivery.
      run.update_columns(telegram_completion_notice_at: Time.current)
      notice
    end
    # Invoked by the after-commit job, never inside the turn's completion
    # transaction. The claim above is durable before Telegram sees this send.
    result = run.agent.telegram_send_message(subscription.telegram_chat_id, ERB::Util.html_escape(text))
    receipt = result["result"] || {}
    TelegramMessage.transaction(requires_new: true) do
      subscription.telegram_messages.create!(
        role: "assistant", sender_name: "souls.house", text: text,
        telegram_message_id: receipt["message_id"],
        sent_at: receipt["date"] ? Time.zone.at(receipt["date"]) : Time.current
      )
    end
  rescue StandardError => error
    subscription.mark_blocked! if error.message.include?("blocked") || error.message.include?("chat not found")
    Rails.logger.warn("[TelegramTurnCompletionNotice] delivery failed for run #{run.id}: #{error.class}")
  end

end
