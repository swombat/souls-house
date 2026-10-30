# The Telegram groups a resident's bot has been added to (#596). Anyone in
# the account may read a group's copied thread; only an owner may allow or
# stop a group, because an allowed group spends the account's allowance.
class Agents::TelegramGroupsController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!, only: :update
  before_action :set_group

  def show
    render inertia: "agents/telegram_group", props: {
      agent: { id: @agent.to_param, name: @agent.name, bot_username: @agent.telegram_bot_username },
      group: TelegramGroupPresentation.group(@group, account: current_account, agent: @agent),
      messages: transcript,
      # getMe said the bot can't read all group messages (BotFather privacy
      # mode on). nil means the house hasn't been told either way.
      privacy_mode_on: @agent.telegram_reads_all_group_messages == false,
      settings_path: edit_account_agent_path(current_account, @agent, tab: "integrations")
    }
  end

  def update
    allowed = ActiveModel::Type::Boolean.new.cast(params.require(:allowed))
    if allowed && @group.removed_at
      return redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"),
        alert: "#{@agent.name} is no longer in that group. Add the bot back first."
    end

    if allowed && !@group.allowed?
      @group.allow!(by: Current.user)
      TelegramGroupNoticeJob.perform_later(@group)
      notice = "#{@agent.name} can now answer in #{@group.subscriber_name}."
    elsif !allowed && @group.allowed?
      @group.disallow!
      notice = "#{@agent.name} will no longer answer in #{@group.subscriber_name}."
    end

    redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"), notice: notice
  end

  private

  def set_group
    @group = @agent.telegram_groups.find(params[:id])
  end

  def transcript
    messages = @group.telegram_messages.chronological.last(500)
    own_ids = messages.select { |message| message.role == "assistant" }.filter_map(&:telegram_message_id).to_set
    messages.map { |message| message_props(message, own_ids) }
  end

  def message_props(message, own_ids)
    {
      id: message.to_param,
      role: message.role,
      sender_name: message.sender_name,
      sender_username: message.sender_username,
      text: message.text,
      sent_at: message.sent_at.iso8601,
      # A person's message that mentioned, replied to or named the resident,
      # as against the group's conversation around it (#646).
      addressed: message.role == "user" && message.addressed?,
      replying_to_resident: own_ids.include?(message.reply_to_telegram_message_id)
    }
  end

end
