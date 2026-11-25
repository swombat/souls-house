class ApiKeysController < ApplicationController

  before_action :require_account

  def index
    unless params[:account_id]
      redirect_to account_api_keys_path(current_account)
      return
    end

    render inertia: "api_keys/index", props: {
      account: current_account,
      external_access_keys: external_access_keys.by_creation.map { |key| ApiKeyPresentation.new(key).as_json },
      resident_keys: resident_keys,
      key_residents: key_residents
    }
  end

  def create
    api_key = ApiKey.generate_for(Current.user, account: current_account, name: params[:name])

    render inertia: "api_keys/show", props: {
      account: current_account,
      api_key: ApiKeyPresentation.new(api_key).as_json,
      raw_token: api_key.raw_token
    }
  end

  def destroy
    external_access_keys.find(params[:id]).destroy!
    redirect_to account_api_keys_path(current_account), notice: "API key revoked"
  end

  private

  def external_access_keys
    Current.user.api_keys.where(account: current_account, agent_id: nil)
  end

  def resident_keys
    current_account.api_keys.where(agent: current_account.agents).includes(:agent).by_creation.map do |key|
      ApiKeyPresentation.new(key).as_json.merge(
        kind: key.resident_named? ? "other_body" : "house",
        resident_active: key.agent.active?
      )
    end
  end

  def key_residents
    return [] unless Setting.feature_enabled?(:agents) && current_account.owned_by?(Current.user)

    current_account.agents.where(runtime: Agent::HOSTED_RUNTIMES).order(:name).map do |agent|
      {
        id: agent.to_param,
        name: agent.name,
        resident_active: agent.active?,
        settings_url: edit_account_agent_path(current_account, agent, tab: "settings", anchor: "connect-another-body")
      }
    end
  end

end
