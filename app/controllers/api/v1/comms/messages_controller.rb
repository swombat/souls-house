module Api
  module V1
    module Comms
      # Messages in one chat, oldest first. With since, the first `limit`
      # messages after it (page forward by passing the last sent_at back);
      # without, the latest `limit`.
      class MessagesController < BaseController

        def index
          chat = find_chat
          scope = chat.comms_messages.includes(:comms_chat)
          messages = if params[:since].present?
            scope.where("comms_messages.sent_at > ?", since).order(:sent_at, :id).limit(limit).to_a
          else
            scope.order(sent_at: :desc, id: :desc).limit(limit).to_a.reverse
          end
          render json: { chat: chat.as_comms_json, messages: messages.map(&:as_comms_json) }
        end

        private

        def find_chat
          value = params.require(:chat).to_s
          if value.match?(/\Achat_\d+\z/)
            @connection.comms_chats.find(value.delete_prefix("chat_"))
          else
            @connection.comms_chats.find_by!(provider_chat_id: value)
          end
        end

        def since
          @since ||= Time.iso8601(params[:since].to_s)
        rescue ArgumentError
          raise ActionController::BadRequest, "since must be an ISO 8601 time"
        end

      end
    end
  end
end
