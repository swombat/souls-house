# The owner's switch for a resident's paid API-key fallback (#690). Owner only:
# it spends the account's own provider key. Turning it on records who did it
# and when; every change is audited.
class Agents::FallbackPoliciesController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!

  def show
    render json: policy_json
  end

  def update
    policy = @agent.fallback_policy || @agent.build_fallback_policy
    attributes = params.require(:fallback_policy).permit(:enabled, :model_id, :cap_usd, :cap_period)
    policy.assign_attributes(attributes)
    if policy.enabled? && (policy.will_save_change_to_enabled? || policy.enabled_by_user_id.nil?)
      policy.enabled_by_user = Current.user
      policy.enabled_at = Time.current
      # Each time it is turned on, the owner is told again on first use.
      policy.first_used_at = nil
    end
    if policy.save
      audit("update_resident_fallback", @agent, **policy.slice(:enabled, :model_id, :cap_usd, :cap_period).symbolize_keys)
      render json: policy_json
    else
      render json: { error: policy.errors.full_messages.to_sentence }, status: :unprocessable_entity
    end
  end

  private

  def policy_json
    policy = @agent.fallback_policy
    decision = ResidentFallback::Decision.for(@agent)
    {
      enabled: policy&.enabled? || false,
      model_id: policy&.model_id,
      model_label: policy&.model_label,
      payer: policy&.payer || "openrouter",
      payer_key_present: @agent.account.openrouter_api_key.present?,
      cap_usd: policy&.cap_usd&.to_s,
      cap_period: policy&.cap_period || "month",
      committed_usd: policy && policy.committed_usd.round(2).to_s,
      period_ends_at: policy&.period_end&.iso8601,
      enabled_at: policy&.enabled_at&.iso8601,
      first_used_at: policy&.first_used_at&.iso8601,
      available: Setting.instance.paid_fallback_enabled?,
      imported_home: @agent.imported_home?,
      api_keys_url: account_agent_api_keys_path(@agent.account),
      status: decision.code || "ready",
      status_reason: decision.reason,
      model_choices: ResidentFallback::Models.choices
    }
  end

end
