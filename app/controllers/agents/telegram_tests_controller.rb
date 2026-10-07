class Agents::TelegramTestsController < ApplicationController

  include AgentScoped

  def create
    unless @agent.telegram_configured?
      return redirect_to edit_account_agent_path(current_account, @agent), alert: "Telegram bot is not configured."
    end

    subscriptions = @agent.telegram_subscriptions.active
    if subscriptions.none?
      return redirect_to edit_account_agent_path(current_account, @agent), alert: "No users have connected to this bot yet."
    end

    subscriptions.each do |sub|
      @agent.telegram_send_message(sub.telegram_chat_id, "Test message from #{@agent.name}.\n\nIf you see this, Telegram messaging is working!")
    end

    redirect_to edit_account_agent_path(current_account, @agent), notice: "Test message sent to #{subscriptions.count} subscriber(s)."
  rescue TelegramNotifiable::TelegramError => e
    redirect_to edit_account_agent_path(current_account, @agent), alert: "Telegram error: #{e.message}"
  end

end
