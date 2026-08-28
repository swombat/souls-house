class SafeguardWeeklyDigestJob < ApplicationJob

  queue_as :default

  def perform
    Account.enabled.find_each { |account| send_account_digest(account) }
  end

  private

  def send_account_digest(account)
    detections = SafeguardDetection.where(agent: account.agents).where(created_at: 1.week.ago..)
    classifier_failures = SafeguardClassifierFailure.where(agent: account.agents).where(created_at: 1.week.ago..)
    agent_ids = detections.distinct.pluck(:agent_id) | classifier_failures.distinct.pluck(:agent_id)
    return if agent_ids.empty?

    account.agents.where(id: agent_ids).find_each do |agent|
      owner_subscription = agent.telegram_subscriptions.active.find_by(user: account.owner)
      next unless owner_subscription

      text = digest_text(
        agent,
        detections.where(agent: agent),
        classifier_failures.where(agent: agent)
      )
      result = agent.telegram_send_message(owner_subscription.telegram_chat_id, ERB::Util.html_escape(text))
      message = result["result"] || {}
      owner_subscription.telegram_messages.create!(
        role: "assistant",
        text: text,
        sender_name: "souls.house",
        telegram_message_id: message["message_id"],
        sent_at: message["date"] ? Time.zone.at(message["date"]) : Time.current
      )
    end
  end

  def digest_text(agent, detections, classifier_failures)
    total = detections.count
    reclaimed = detections.where.not(reclaimed_at: nil).count
    repeated_after_roll = repeat_after_roll_count(detections)
    failure_count = classifier_failures.count
    groups = detections.group(:provider, :model, :detector_version).count.map do |(provider, model, version), count|
      "- #{provider || "unknown"}/#{model || "unknown"} · #{version}: #{count}"
    end

    <<~TEXT.strip
      souls.house safeguard digest for #{agent.name} — last 7 days

      Detections: #{total}
      Classifier failures: #{failure_count}
      Reclaimed: #{reclaimed} (#{percentage(reclaimed, total)})
      Repeated after an automatic roll: #{repeated_after_roll} (#{percentage(repeated_after_roll, total)})

      #{groups.join("\n")}
    TEXT
  end

  def repeat_after_roll_count(detections)
    detections.includes(telegram_message: :telegram_subscription)
      .group_by { |detection| detection.telegram_message&.telegram_subscription_id }
      .sum do |_subscription_id, thread_detections|
        thread_detections.sort_by(&:created_at).each_cons(2).count do |previous, _current|
          previous.session_rolled_at.present?
        end
      end
  end

  def percentage(numerator, denominator)
    return "0%" if denominator.zero?

    "#{(numerator * 100.0 / denominator).round}%"
  end

end
