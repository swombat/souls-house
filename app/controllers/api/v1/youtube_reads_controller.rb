module Api
  module V1
    class YoutubeReadsController < BaseController

      rate_limit to: 20, within: 1.hour, only: :create,
        by: -> { request.headers["Authorization"].to_s },
        with: -> { render json: { error: "YouTube reading limit reached; try again later" }, status: :too_many_requests }

      def create
        unless current_api_agent
          return render json: { error: "YouTube reading is only available to agent API keys" }, status: :forbidden
        end

        result = YoutubeVideoReader.new.call(
          url: params[:url],
          operation: params[:operation],
          question: params[:question]
        )
        render json: result
      rescue YoutubeVideoReader::InvalidRequest => e
        render json: { error: e.message }, status: :unprocessable_entity
      rescue YoutubeVideoReader::ConfigurationError => e
        render json: { error: e.message }, status: :service_unavailable
      rescue YoutubeVideoReader::UpstreamError => e
        render json: { error: e.message }, status: :bad_gateway
      end

    end
  end
end
