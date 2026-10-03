module Api
  module V1
    class TelegramMediaController < BaseController

      include AttachmentDownloads

      def show
        return render_agent_key_required unless current_api_agent

        message = telegram_message
        raise ActiveRecord::RecordNotFound unless message.media.attached?

        redirect_to download_url_for(message.media), allow_other_host: true
      end

      def preview_frame
        return render_agent_key_required unless current_api_agent

        attachment = telegram_message.preview_frames_attachments.find(params[:id])
        redirect_to download_url_for(attachment), allow_other_host: true
      end

      private

      def telegram_message
        subscription = current_api_agent.telegram_subscriptions.find(params[:conversation_id])
        subscription.telegram_messages.find(params[:message_id])
      end

      def render_agent_key_required
        render json: { error: "Telegram media is only available to Resident API keys" }, status: :forbidden
      end

    end
  end
end
