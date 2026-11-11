# Tells an account's owner when a resident starts spending on its paid
# fallback (#690 slice C): which model, that the account's own OpenRouter key
# pays, the cap, and where to turn it off. Sent on the first paid call in each
# cap period and after the fallback is turned off and on
# (ResidentFallback::UseNotice).
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
    mail(to: @owner.email_address, subject: "#{@agent.name} has started using your paid fallback")
  end

end
