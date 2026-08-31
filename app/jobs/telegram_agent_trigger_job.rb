class TelegramAgentTriggerJob < ApplicationJob

  class SessionBusy < StandardError; end

  queue_as :default
  limits_concurrency(
    to: 1,
    key: ->(subscription, _telegram_message) { "telegram-subscription-#{subscription.id}" },
    duration: 35.minutes
  )
  retry_on SessionBusy, wait: 30.seconds, attempts: 60

  def perform(subscription, telegram_message)
    agent = subscription.agent
    return unless agent.active? && !agent.paused? && agent.external? && agent.trigger_bearer_token.present?

    result = ExternalAgentTelegramRequest.new(
      agent: agent,
      subscription: subscription,
      telegram_message: telegram_message
    ).call
    raise SessionBusy, "Telegram session is already processing another message" if result[:status] == 409
  end

end
