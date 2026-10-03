class ApiKeysController < ApplicationController

  before_action :require_account

  def index
    unless params[:account_id]
      redirect_to account_api_keys_path(current_account)
      return
    end

    render inertia: "api_keys/index", props: {
      account: current_account,
      external_access_keys: external_access_keys.by_creation.map { |key| api_key_json(key) },
      chaos_agent_access_keys: chaos_agent_access_keys.by_creation.map { |key| api_key_json(key) }
    }
  end

  def create
    api_key = ApiKey.generate_for(Current.user, account: current_account, name: params[:name])

    render inertia: "api_keys/show", props: {
      account: current_account,
      api_key: api_key_json(api_key),
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

  def chaos_agent_access_keys
    current_account.api_keys.where.not(agent_id: nil).includes(:agent, :user)
  end

  def api_key_json(key)
    {
      id: key.id,
      name: key.name,
      prefix: key.display_prefix,
      actor: api_key_actor_json(key),
      created_at: key.created_at.strftime("%b %d, %Y"),
      last_used_at: key.last_used_at&.strftime("%b %d, %Y at %l:%M %p"),
      last_used_ip: key.last_used_ip
    }
  end

  def api_key_actor_json(key)
    if key.agent
      { type: "agent", id: key.agent.to_param, name: key.agent.name }
    else
      { type: "user", id: key.user.to_param, name: key.user.display_name }
    end
  end

end
