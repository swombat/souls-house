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
    result = auth_client.cancel(provider:)
    end_pending_sign_in!("cancelled")
    render json: result
  rescue AgentProviderAuthClient::Error => e
    render_client_error(e)
  end

  def code
    render json: auth_client.submit_code(provider:, code: params.require(:code))
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
      previous_status = @agent.provider_connection(provider)["status"]
      @agent.record_provider_connection!(
        provider,
        email: result["email"],
        plan: result["plan"],
        status: "connected",
        connected_at: @agent.provider_connection(provider)["connected_at"] || Time.current.iso8601
      )
      if @agent.provider_sign_in_pending?(provider)
        audit(Agent::PROVIDER_SIGNED_IN, @agent, **{ provider:, plan: result["plan"], previous_status: }.compact)
      elsif previous_status == "expired"
        audit(Agent::PROVIDER_RECOVERED, @agent, **{ provider:, plan: result["plan"] }.compact)
      end
    when "expired"
      # The runtime's sign-in attempt timed out (auth_status), not the login.
      end_pending_sign_in!("attempt_expired")
    when "none"
      @agent.clear_provider_connection!(provider) if @agent.provider_connection(provider).present?
    end
  end

  def end_pending_sign_in!(reason)
    audit(Agent::PROVIDER_SIGN_IN_ENDED, @agent, provider:, reason:) if @agent.provider_sign_in_pending?(provider)
  end

  def render_client_error(error)
    render json: { error: error.message }, status: error.status || :bad_gateway
  end

end
