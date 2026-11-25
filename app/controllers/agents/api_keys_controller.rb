# Named keys for a resident's bodies outside the house (e.g. "Janis — Desktop").
# Each acts exactly as the resident's container key does: it posts as the
# resident and reads what the resident can read, because a key with an agent
# authenticates as that agent everywhere (ApiKey.authenticate). Owners create
# and revoke them one at a time; the container key itself is replaced only by
# Agents::RotateCredentials, which also removes every named key.
class Agents::ApiKeysController < ApplicationController

  before_action :require_account
  before_action :require_account_owner!
  before_action :set_hosted_resident

  def create
    label = params[:name].to_s.strip
    if label.blank?
      redirect_to settings_path, alert: "Give the key a name, such as Desktop"
      return
    end

    api_key = ApiKey.generate_for(Current.user, agent: @agent, account: current_account, name: label)
    audit(:create_resident_api_key, api_key, agent_id: @agent.id, name: api_key.name, prefix: api_key.token_prefix)

    render inertia: "api_keys/show", props: {
      account: current_account,
      api_key: ApiKeyPresentation.new(api_key).as_json,
      raw_token: api_key.raw_token,
      return_url: settings_path
    }
  rescue ActiveRecord::RecordInvalid => e
    redirect_to settings_path, alert: e.record.errors.full_messages.to_sentence
  end

  def destroy
    api_key = ApiKey.resident_named.where(account: current_account, agent: @agent).find(params[:id])
    api_key.destroy!
    audit(:revoke_resident_api_key, api_key, agent_id: @agent.id, name: api_key.name, prefix: api_key.token_prefix)
    redirect_to settings_path, notice: "Key revoked. #{@agent.name}'s other keys still work."
  end

  private

  def set_hosted_resident
    @agent = current_account.agents.where(runtime: Agent::HOSTED_RUNTIMES).find(params[:agent_id])
  end

  def settings_path
    edit_account_agent_path(current_account, @agent, tab: "settings", anchor: "connect-another-body")
  end

end
