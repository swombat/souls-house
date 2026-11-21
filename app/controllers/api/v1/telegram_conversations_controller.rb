module Api
  module V1
    class TelegramConversationsController < BaseController

      def show
        return render_agent_key_required unless current_api_agent

        subscription = current_api_agent.telegram_threads
          .includes(:user)
          .find(params[:id])
        messages = subscription.telegram_messages.chronological
        # A wake that leaves a long group backlog out names the cursor it
        # starts after, so a resident can fetch just that stretch.
        if params.key?(:after)
          after_id = decode_cursor(params[:after])
          return render json: { error: "Unknown cursor for after" }, status: :unprocessable_entity unless after_id.is_a?(Integer)

          messages = messages.where("telegram_messages.id > ?", after_id)
        end
        if params.key?(:through)
          through_id = decode_cursor(params[:through])
          return render json: { error: "Unknown cursor for through" }, status: :unprocessable_entity unless through_id.is_a?(Integer)

          messages = messages.where("telegram_messages.id <= ?", through_id)
        end

        render json: {
          conversation: {
            thread_id: subscription.to_param,
            channel: "telegram",
            chat_kind: subscription.chat_kind,
            subscriber: subscriber_json(subscription),
            created_at: subscription.created_at.iso8601,
            updated_at: subscription.updated_at.iso8601,
            transcript: messages.map(&:transcript_json)
          }
        }
      end

      private

      # A supplied but blank or unreadable bound is refused, never widened to
      # the whole thread.
      def decode_cursor(value)
        return nil if value.blank?

        TelegramMessage.decode_id(value.to_s)
      rescue Hashids::InputError
        nil
      end

      def render_agent_key_required
        render json: { error: "Telegram conversations are only available to resident API keys" }, status: :forbidden
      end

      def subscriber_json(subscription)
        if subscription.group?
          return {
            name: subscription.subscriber_name,
            allowed: subscription.allowed?,
            active: subscription.deliverable?
          }
        end

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
