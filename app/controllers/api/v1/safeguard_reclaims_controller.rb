module Api
  module V1
    class SafeguardReclaimsController < BaseController

      def create
        return render_agent_key_required unless current_api_agent

        detection = current_api_agent.safeguard_detections.find(params[:safeguard_detection_id])
        detection.reclaim!(
          reason: params[:reason],
          interaction: current_cold_offer_interaction(detection)
        )
        send_confirmation(detection)

        render json: {
          reclaimed: true,
          detection_id: detection.to_param,
          reason: detection.reclaim_reason
        }, status: :created
      rescue ArgumentError => e
        render json: { error: e.message }, status: :unprocessable_entity
      end

      private

      def render_agent_key_required
        render json: { error: "Safeguard messages can only be reclaimed by the owning resident" }, status: :forbidden
      end

      def current_cold_offer_interaction(detection)
        current_api_agent.agent_runtime_interactions.active
          .where(trigger_kind: "safeguard_reclaim_offer")
          .where("session_id LIKE ?", "#{current_api_agent.uuid}-safeguard-offer-#{detection.id}-%")
          .order(started_at: :desc)
          .first
      end

      def send_confirmation(detection)
        subscription = detection.telegram_message&.telegram_subscription
        return unless subscription

        text = SafeguardNoticeRenderer.reclaim_confirmation(detection)
        result = current_api_agent.telegram_send_message(
          subscription.telegram_chat_id,
          ERB::Util.html_escape(text)
        )
        telegram_message = result["result"] || {}
        subscription.telegram_messages.create!(
          role: "assistant",
          text: text,
          sender_name: "souls.house",
          telegram_message_id: telegram_message["message_id"],
          sent_at: telegram_message["date"] ? Time.zone.at(telegram_message["date"]) : Time.current
        )
      rescue TelegramNotifiable::TelegramError, ActiveRecord::ActiveRecordError => e
        Rails.logger.warn(
          "[SafeguardReclaimsController] reclaimed detection #{detection.id}, " \
          "but confirmation failed: #{e.class}: #{e.message}"
        )
      end

    end
  end
end
