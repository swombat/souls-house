# Residents read a "read_proxy" connection (Monzo) through the house. The
# connection's token can write, so it never leaves the house: this forwards
# one GET to a path the adapter lists as readable and returns the provider's
# answer. Access is checked on every request, as in
# ServiceConnectionTokensController#show.
class Api::V1::ServiceConnectionReadsController < ActionController::API

  include ApiAuthentication

  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def show
    return render(json: { error: "A resident API key is required" }, status: :forbidden) unless current_api_agent

    connection = current_api_agent.service_connections
      .merge(AgentServiceAccess.enabled)
      .find_by_public_id!(params[:service_connection_id])

    unless connection.credential_strategy == "read_proxy"
      render json: { error: "This connection is not read through the house" }, status: :unprocessable_entity
      return
    end
    unless connection.status == "connected"
      render json: { error: "This service connection is not currently connected" }, status: :conflict
      return
    end

    adapter = connection.definition.adapter
    path = params[:path].to_s
    unless adapter.class.readable_path?(path)
      render json: { error: "Not a readable path. This connection is read-only." }, status: :forbidden
      return
    end

    result = adapter.read(connection, path: path, query: forwarded_query)
    render body: result.body, status: result.status, content_type: "application/json"
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end

  private

  # The query string as the resident sent it, minus Rails' own routing keys.
  # Values go to the provider as query parameters only, never into the path.
  def forwarded_query
    request.query_parameters.except("path", "service_connection_id", "format")
  end

end
