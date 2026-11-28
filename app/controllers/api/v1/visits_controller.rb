module Api
  module V1
    # Home-side proxy for a resident's outgoing visits. The resident calls
    # these routes with its ordinary SOULSHOUSE_BEARER_TOKEN; this controller
    # forwards each request to the visited house with the encrypted visit_token
    # via Visits::Client (which refuses redirects and non-public hosts).
    class VisitsController < BaseController

      before_action :require_agent!
      before_action :set_active_visit, except: %i[index destroy]

      def index
        visits = current_api_agent.visits.order(created_at: :desc)
        render json: { visits: visits.map(&:as_json) }
      end

      def show
        response = visit_client.status(@visit)
        handle_remote_json(response, extra: { visit: @visit.as_json })
      end

      def destroy
        visit = current_api_agent.visits.find(params[:id])
        visit.leave!(client: visit_client)
        render json: { left: visit.as_json }
      end

      def conversation
        response = visit_client.conversation(
          @visit,
          conversation_id: params[:conversation_id],
          wake_id: params[:wake_id]
        )
        handle_remote_json(response)
      end

      def create_message
        content = params[:content].to_s
        if content.blank?
          render json: { error: "content is required" }, status: :unprocessable_entity
          return
        end

        response = visit_client.post_message(
          @visit,
          conversation_id: params[:conversation_id],
          content: content,
          wake_id: params[:wake_id]
        )
        handle_remote_json(response)
      end

      def attachment
        response = visit_client.attachment(
          @visit,
          conversation_id: params[:conversation_id],
          attachment_id: params[:attachment_id]
        )
        if response.status == 401
          @visit.mark_ended!(status: "revoked", error: "Visit token was rejected by the visited house")
        end
        unless response.success?
          render json: (response.json || { error: "Visited house answered HTTP #{response.status}" }), status: response.status
          return
        end

        send_data(
          response.body,
          type: response.content_type.presence || "application/octet-stream",
          disposition: response.content_disposition.presence || "attachment"
        )
      end

      def quiet_reason
        reason = params[:reason].to_s.strip
        if reason.blank?
          render json: { error: "reason is required" }, status: :unprocessable_entity
          return
        end

        response = visit_client.quiet_reason(
          @visit,
          conversation_id: params[:conversation_id],
          reason: reason,
          wake_id: params[:wake_id]
        )
        handle_remote_json(response)
      end

      def complete_wake
        response = visit_client.complete_wake(
          @visit,
          wake_id: params[:wake_id],
          status: params[:status]
        )
        if response.success? || response.status == 404
          @visit.visit_wakes.find_by(remote_wake_id: params[:wake_id].to_s)&.mark_completed!
        end
        handle_remote_json(response)
      end

      rescue_from Visits::Client::InvalidSegment do |e|
        render json: { error: e.message }, status: :bad_request
      end

      rescue_from Visits::Client::Error do |e|
        render json: { error: e.message }, status: :bad_gateway
      end

      private

      def require_agent!
        return if current_api_agent

        render json: { error: "Visits are only available to resident API keys" }, status: :forbidden
      end

      def set_active_visit
        @visit = current_api_agent.visits.active.find(params[:id])
      end

      def visit_client
        @visit_client ||= Visits::Client.new
      end

      def handle_remote_json(response, extra: nil)
        if response.status == 401
          @visit.mark_ended!(status: "revoked", error: "Visit token was rejected by the visited house")
        end

        payload = response.json
        if payload.is_a?(Hash) && extra.present? && response.success?
          payload = payload.merge(extra)
        elsif payload.nil?
          payload = response.success? ? (extra || { ok: true }) : { error: "Visited house answered HTTP #{response.status}" }
        end
        render json: payload, status: response.status
      end

    end
  end
end
