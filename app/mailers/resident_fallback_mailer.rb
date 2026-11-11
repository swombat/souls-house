# Tells an account's owner the first time a resident answers on its paid
# fallback (#690 slice C): which model, that the account's own OpenRouter key
# pays, the cap, and where to turn it off. Once per time it is turned on
# (ResidentFallback::Hop.notify_first_use).
class ResidentFallbackMailer < ApplicationMailer

  def first_use(turn)
    @turn = turn
    @agent = turn.agent
    @account = @agent.account
    @owner = @account.owner
    @policy = @agent.fallback_policy
    return unless @owner&.email_address.present? && @policy

    @model_label = ResidentFallback::Models.label(turn.fallback_model_id)
    @cap = format("%.2f", @policy.cap_usd)
    @settings_url = edit_account_agent_url(@account, @agent, tab: "settings")
    @conversation_url = turn.chat && account_chat_url(@account, turn.chat)
    mail(to: @owner.email_address, subject: "#{@agent.name} is answering on your paid fallback")
  end

end
