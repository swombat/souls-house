# The resident settings a person may submit, shared by the web resident pages
# and the human-key API so both permit, strip and audit exactly the same way.
# Expects `params` and, for updates, `@agent`.
module AgentSettingsParams

  extend ActiveSupport::Concern

  private

  def agent_params
    permitted = params.require(:agent).permit(
      :name, :system_prompt,
      :model_id, :active, :paused, :colour, :icon,
      :thinking_enabled, :thinking_budget, :reasoning_effort,
      :telegram_bot_token, :telegram_bot_username,
      :voice_id, :persistent_session, :persistent_wake_session, :scheduled_wakes_enabled,
      :heartbeat_wakes_per_day, :session_idle_timeout_minutes, :session_max_age_minutes,
      :session_context_budget_tokens, :turn_timeout_minutes, :subagents_enabled,
      :resident_may_switch_model,
      subagent_models: [], switchable_model_ids: []
    )

    permitted.delete(:telegram_bot_token) if permitted[:telegram_bot_token].blank?
    strip_externally_managed_params!(permitted) if @agent&.identity_owned_by_agent?
    permitted
  end

  def birth_params
    params.require(:agent).permit(
      :name, :system_prompt, :model_id, :colour, :icon,
      :scheduled_wakes_enabled, :open_beginning
    )
  end

  def strip_externally_managed_params!(permitted)
    Agent::EXTERNALLY_MANAGED_ATTRIBUTES.each do |attribute|
      permitted.delete(attribute)
    end
  end

  def agent_audit_data(attrs)
    attrs.except(:telegram_bot_token).to_h
  end

end
