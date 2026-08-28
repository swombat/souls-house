module Api
  module V1
    class SafeguardDetectionsController < BaseController

      def show
        detection = current_api_agent&.safeguard_detections&.find(params[:id])
        return render_agent_key_required unless detection

        render json: detection_json(detection)
      end

      private

      def render_agent_key_required
        render json: { error: "Safeguard detections are only available to the owning resident" }, status: :forbidden
      end

      def detection_json(detection)
        {
          id: detection.to_param,
          channel: detection.channel,
          response_text: detection.response_text,
          response_text_redacted_at: detection.response_text_redacted_at&.iso8601,
          classifier_reason: detection.classifier_reason,
          detector_version: detection.detector_version,
          reclaimed_at: detection.reclaimed_at&.iso8601,
          reclaim_reason: detection.reclaim_reason,
          created_at: detection.created_at.iso8601
        }
      end

    end
  end
end
