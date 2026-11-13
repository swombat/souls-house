class Api::V1::PostizController < ActionController::API
  include ApiAuthentication
  wrap_parameters false

  before_action -> { response.headers["Cache-Control"] = "no-store" }

  def channels
    operate { |adapter, connection| adapter.list_channels(connection) }
  end

  def draft
    operate do |adapter, connection|
      unless (request.request_parameters.keys - %w[channel_id content]).empty?
        return render json: { error: "Only channel_id and content are accepted; drafts only" }, status: :unprocessable_entity
      end
      adapter.create_draft(connection, channel_id: params[:channel_id], content: params[:content])
    end
  end

  def create
    operate do |adapter, connection|
      unless (request.request_parameters.keys - %w[channel_id content mode scheduled_at settings media]).empty?
        return render json: { error: "Unknown Postiz post fields" }, status: :unprocessable_entity
      end
      settings = params[:settings]
      settings = settings.to_unsafe_h if settings.is_a?(ActionController::Parameters)
      media = params[:media]
      media = media.map { |entry| entry.is_a?(ActionController::Parameters) ? entry.to_unsafe_h : entry } if media.is_a?(Array)
      adapter.create_post(connection, channel_id: params[:channel_id], content: params[:content],
        mode: params[:mode], scheduled_at: params[:scheduled_at],
        settings: settings.nil? ? {} : settings, media: media.nil? ? [] : media)
    end
  end

  def upload
    operate do |adapter, connection|
      unless (request.request_parameters.keys - %w[file]).empty? &&
          params[:file].is_a?(ActionDispatch::Http::UploadedFile)
        return render json: { error: "Upload requires a multipart file; URLs are not accepted" }, status: :unprocessable_entity
      end
      adapter.upload_media(connection, file: params[:file])
    end
  end

  private

  def operate
    return render(json: { error: "A resident API key is required" }, status: :forbidden) unless current_api_agent

    connection = current_api_agent.service_connections.merge(AgentServiceAccess.effective)
      .find_by_public_id!(params[:service_connection_id])
    return render(json: { error: "Not a Postiz connection" }, status: :unprocessable_entity) unless connection.provider == "postiz"
    return render(json: { error: "Connection is not connected" }, status: :conflict) unless connection.status == "connected"

    render json: yield(connection.definition.adapter, connection)
  rescue Services::AdapterError => e
    render json: { error: e.message }, status: :bad_gateway
  end
end
