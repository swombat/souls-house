# What the resident's settings page shows about its Telegram groups (#596).
module TelegramGroupPresentation

  module_function

  def list(agent, account:)
    agent.telegram_groups.order(:created_at).map { |group| group(group, account: account, agent: agent) }
  end

  def group(group, account:, agent:)
    helpers = Rails.application.routes.url_helpers
    {
      id: group.to_param,
      title: group.subscriber_name,
      allowed: group.allowed?,
      removed: group.removed_at.present?,
      allowed_at: group.allowed_at&.iso8601,
      allowed_by: group.allowed_by && ResidentFacingName.for(group.allowed_by),
      message_count: group.telegram_messages.count,
      path: helpers.account_agent_telegram_group_path(account, agent, group)
    }
  end

end
