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
    announce = false
    @group.with_lock do
      was_allowed = @group.allowed?
      answered_bots = @group.answers_bots?
      @group.assign_attributes(group_params)
      if @group.allowed? && @group.removed_at
        return redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"),
          alert: "#{@agent.name} is no longer in that group. Add the bot back first."
      end
      if @group.allowed? && !was_allowed
        @group.allowed_at = Time.current
        @group.allowed_by = Current.user
      end
      @group.save!
      announce = @group.allowed? && !@group.removed_at &&
        (!was_allowed || (@group.answers_bots? && !answered_bots))
    end
    TelegramGroupNoticeJob.perform_later(@group) if announce

    redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"),
      notice: "Telegram group settings saved."
  rescue ActiveRecord::RecordInvalid
    redirect_back_or_to edit_account_agent_path(current_account, @agent, tab: "integrations"),
      alert: @group.errors.full_messages.to_sentence
  end

  private

  def group_params
    permitted = params.permit(:allowed, :answers_bots, answer_bot_usernames: [])
    # A cleared text/list control means any bot, not an unchanged allowlist.
    permitted[:answer_bot_usernames] = [] if params[:answer_bot_usernames].is_a?(String) && params[:answer_bot_usernames].blank?
    permitted
  end

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
      # An admitted message that addressed the resident (including other bots),
      # as against the group's conversation around it (#646).
      addressed: message.role == "user" && message.addressed?,
      replying_to_resident: own_ids.include?(message.reply_to_telegram_message_id)
    }
  end

end
