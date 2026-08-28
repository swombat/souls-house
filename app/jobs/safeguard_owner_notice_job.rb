class SafeguardOwnerNoticeJob < ApplicationJob

  queue_as :default

  discard_on ActiveRecord::RecordNotFound

  def perform(detection)
    subscription = detection.telegram_message&.telegram_subscription
    return unless subscription

    threshold = Setting.instance.safeguard_owner_notice_threshold
    count = consecutive_count(detection, subscription)
    return unless count == threshold

    owner = detection.agent.account.owner
    return unless owner

    owner_subscription =
      if subscription.user_id == owner.id
        subscription
      else
        detection.agent.telegram_subscriptions.active.find_by(user: owner)
      end
    unless owner_subscription
      Rails.logger.info("[SafeguardOwnerNoticeJob] no owner Telegram subscription for detection #{detection.id}")
      return
    end

    plural = "s" unless count == 1
    text = "souls.house detected #{count} consecutive possible safeguard response#{plural} for #{detection.agent.name} in Telegram thread #{subscription.to_param}. Detection: #{detection.to_param}. Reclaimed: #{detection.reclaimed? ? "yes" : "no"}."
    result = detection.agent.telegram_send_message(
      owner_subscription.telegram_chat_id,
      ERB::Util.html_escape(text)
    )
    record_platform_message(owner_subscription, text, result)
  end

  private

  def consecutive_count(detection, subscription)
    detected_message_ids = SafeguardDetection.where(agent: detection.agent)
      .where.not(telegram_message_id: nil)
      .select(:telegram_message_id)
    last_normal_id = subscription.telegram_messages
      .where(role: "assistant", sender_name: detection.agent.name)
      .where.not(id: detected_message_ids)
      .maximum(:id) || 0

    SafeguardDetection.joins(:telegram_message)
      .where(agent: detection.agent)
      .where(telegram_messages: { telegram_subscription_id: subscription.id })
      .where("telegram_messages.id > ?", last_normal_id)
      .where("safeguard_detections.id <= ?", detection.id)
      .count
  end

  def record_platform_message(subscription, text, result)
    message = result["result"] || {}
    subscription.telegram_messages.create!(
      role: "assistant",
      text: text,
      sender_name: "souls.house",
      telegram_message_id: message["message_id"],
      sent_at: message["date"] ? Time.zone.at(message["date"]) : Time.current
    )
  end

end
