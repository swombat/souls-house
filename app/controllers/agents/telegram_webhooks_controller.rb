class Agents::TelegramWebhooksController < ApplicationController

  include AgentScoped

  def create
    unless @agent.telegram_configured?
      return redirect_to edit_account_agent_path(current_account, @agent), alert: "Telegram bot is not configured."
    end

    @agent.set_telegram_webhook!
    RefreshTelegramBotInfoJob.perform_later(@agent)
    info = @agent.telegram_webhook_info
    webhook_url = info&.dig("result", "url")

    if webhook_url.present?
      redirect_to edit_account_agent_path(current_account, @agent), notice: "Webhook registered: #{webhook_url}"
    else
      redirect_to edit_account_agent_path(current_account, @agent), alert: "Webhook registration may have failed. Check logs."
    end
  end

end
