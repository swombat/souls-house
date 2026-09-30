module Api
  module V1
    class TelegramConversationsController < BaseController

      def show
        return render_agent_key_required unless current_api_agent

        subscription = current_api_agent.telegram_subscriptions
          .includes(:user)
          .find(params[:id])

        render json: {
          conversation: {
            thread_id: subscription.to_param,
            channel: "telegram",
            subscriber: subscriber_json(subscription),
            created_at: subscription.created_at.iso8601,
            updated_at: subscription.updated_at.iso8601,
            transcript: subscription.telegram_messages.chronological.map(&:transcript_json)
          }
        }
      end

      private

      def render_agent_key_required
        render json: { error: "Telegram conversations are only available to resident API keys" }, status: :forbidden
      end

      def subscriber_json(subscription)
        {
          name: subscription.subscriber_name,
          email: subscription.user.email_address,
          telegram_username: subscription.telegram_username,
          active: !subscription.blocked?
        }
      end

    end
  end
end
