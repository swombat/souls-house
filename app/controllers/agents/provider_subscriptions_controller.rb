class Agents::ProviderSubscriptionsController < ApplicationController

  include AgentScoped

  before_action :require_account_owner!

  def show
    if ActiveModel::Type::Boolean.new.cast(params[:capabilities])
      render json: auth_client.capabilities
      return
    end

    result = auth_client.status(provider:)
    persist_status!(result)
    render json: result
  rescue AgentProviderAuthClient::Error => e
    render_client_error(e)
  end

  def create
    result = auth_client.start(provider:)
    audit(Agent::PROVIDER_SIGN_IN_STARTED, @agent, provider:) unless result["status"] == "connected"
    render json: result
  rescue AgentProviderAuthClient::Error => e
    render_client_error(e)
  end

  def update
    mode = params.require(:auth_mode)
    if mode == "oauth_account" && @agent.provider_connection(provider)["status"] != "connected"
      render json: { error: "Connect the provider account before selecting subscription mode" },
             status: :unprocessable_entity
      return
    end
    @agent.use_provider_auth_mode!(provider, mode)
    audit("update_agent_provider_auth_mode", @agent, provider:, auth_mode: mode)
    render json: { provider:, auth_mode: mode }
  rescue ArgumentError => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  def destroy
    result = auth_client.disconnect(provider:)
    @agent.clear_provider_connection!(provider)
    audit("disconnect_agent_provider_subscription", @agent, provider:)
    render json: result
  rescue AgentProviderAuthClient::Error => e
    render_client_error(e)
  end

  def cancel
    render json: auth_client.cancel(provider:)
  rescue AgentProviderAuthClient::Error => e
    render_client_error(e)
  end

  def code
    result = auth_client.submit_code(provider:, code: params.require(:code))
    audit(Agent::PROVIDER_SIGN_IN_CODE_SUBMITTED, @agent, provider:)
    render json: result
  rescue AgentProviderAuthClient::Error => e
    render_client_error(e)
  end

  private

  def auth_client
    @auth_client ||= AgentProviderAuthClient.new(@agent)
  end

  def provider
    @provider ||= params.require(:provider).to_s
  end

  def persist_status!(result)
    case result["status"]
    when "connected"
      @agent.observe_provider_connected!(provider, email: result["email"], plan: result["plan"])
    when "none"
      @agent.clear_provider_connection!(provider) if @agent.provider_connection(provider).present?
    end
  end

  def render_client_error(error)
    render json: { error: error.message }, status: error.status || :bad_gateway
  end

end
