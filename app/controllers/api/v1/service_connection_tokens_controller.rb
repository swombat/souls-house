class Api::V1::ServiceConnectionTokensController < ActionController::API

  include ApiAuthentication

  def show
    return render(json: { error: "A resident API key is required" }, status: :forbidden) unless current_api_agent

    connection = current_api_agent.service_connections
      .merge(AgentServiceAccess.effective)
      .find_by_public_id!(params[:service_connection_id])

    unless connection.credential_strategy == "refresh_broker"
      render json: { error: "This connection does not use the refresh broker" }, status: :unprocessable_entity
      return
    end
    unless connection.status == "connected"
      return render_google_reauthorization(connection) if connection.provider == "google_workspace" && connection.status == "reauthorizing"

      render json: { error: "This service connection is not currently connected" }, status: :conflict
      return
    end

    access_token = connection.definition.adapter.current_access_token(connection)
    payload = connection.reload.credential_payload_hash
    render json: {
      access_token: access_token,
      expires_at: payload["expires_at"]
    }
  rescue Services::GoogleWorkspaceAdapter::ReauthorizationRequired
    render_google_reauthorization(connection)
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  def render_google_reauthorization(connection)
    render json: {
      error: "provider_reauth_required",
      message: Services::GoogleWorkspaceAdapter::REAUTHORIZATION_MESSAGE,
      connection_id: connection.public_id,
      last_good_refresh: connection.last_refreshed_at&.utc&.iso8601
    }, status: :conflict
  end

end
