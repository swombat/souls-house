class Api::V1::ServiceConnectionTokensController < ActionController::API

  include ApiAuthentication

  def show
    connection = current_api_agent.service_connections
      .merge(AgentServiceAccess.enabled)
      .find_by_public_id!(params[:service_connection_id])

    unless connection.credential_strategy == "refresh_broker"
      render json: { error: "This connection does not use the refresh broker" }, status: :unprocessable_entity
      return
    end
    unless connection.status == "connected"
      render json: { error: "This service connection is not currently connected" }, status: :conflict
      return
    end

    access_token = connection.definition.adapter.current_access_token(connection)
    payload = connection.reload.credential_payload_hash
    render json: {
      access_token: access_token,
      expires_at: payload["expires_at"]
    }
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

end
