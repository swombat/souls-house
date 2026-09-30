module Api
  module V1
    class TelegramSubscribersController < BaseController

      def index
        unless current_api_agent
          return render json: { error: "Telegram subscribers are only available to resident API keys" }, status: :forbidden
        end

        subscriptions = current_api_agent.telegram_subscriptions.includes(:user).order(:created_at)
        render json: {
          subscribers: subscriptions.map do |subscription|
            {
              thread_id: subscription.to_param,
              name: subscription.subscriber_name,
              email: subscription.user.email_address,
              telegram_username: subscription.telegram_username,
              active: !subscription.blocked?
            }
          end
        }
      end

    end
  end
end
