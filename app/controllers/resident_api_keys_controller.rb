# Named keys for a resident's bodies outside the house (e.g. "Janis — Desktop").
# Each acts exactly as the resident's container key does: it posts as the
# resident and reads what the resident can read, because a key with an agent
# authenticates as that agent everywhere (ApiKey.authenticate). Owners create
# and revoke them one at a time; the container key itself is replaced only by
# Agents::RotateCredentials, which also removes every named key.
class ResidentApiKeysController < ApplicationController

  before_action :require_account
  before_action :require_owner!

  def create
    agent = resident_choices.find(params[:agent_id])
    label = params[:name].to_s.strip
    if label.blank?
      redirect_to account_api_keys_path(current_account), alert: "Give the key a name, such as Desktop"
      return
    end

    api_key = ApiKey.generate_for(Current.user, agent: agent, account: current_account, name: label)
    audit(:create_resident_api_key, api_key, agent_id: agent.id, name: api_key.name, prefix: api_key.token_prefix)

    render inertia: "api_keys/show", props: {
      account: current_account,
      api_key: { id: api_key.id, name: api_key.name, prefix: api_key.display_prefix,
                 actor: { type: "agent", id: agent.to_param, name: agent.name } },
      raw_token: api_key.raw_token
    }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to account_api_keys_path(current_account), alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    api_key = ApiKey.resident_named.where(account: current_account).find(params[:id])
    api_key.destroy!
    audit(:revoke_resident_api_key, api_key, agent_id: api_key.agent_id, name: api_key.name, prefix: api_key.token_prefix)
    redirect_to account_api_keys_path(current_account), notice: "Key revoked. #{api_key.agent.name}'s other keys still work."
  end

  private

  def require_owner!
    deny_account_access!("Only account owners can manage residents' keys") unless current_account.owned_by?(Current.user)
  end

  def resident_choices
    current_account.agents.where(runtime: Agent::HOSTED_RUNTIMES)
  end

end
