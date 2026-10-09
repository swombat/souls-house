module Api
  module V1
    module Comms
      # Messages in one chat, oldest first.
      #   - no since/after: the latest `limit`.
      #   - since (ISO 8601, inclusive): the first `limit` at or after it.
      #   - after (an opaque cursor from next_cursor): the first `limit`
      #     strictly after that (sent_at, id) position. WhatsApp timestamps
      #     are whole seconds, so paging on time alone either skips or
      #     repeats; the (sent_at, id) cursor does neither.
      # next_cursor is present when a full page came back and is null when
      # the reader has caught up.
      class MessagesController < BaseController

        def index
          chat = find_chat
          scope = chat.comms_messages.includes(:comms_chat)
          messages = if params[:after].present?
            cursor_sent_at, cursor_id = cursor
            scope.where("(comms_messages.sent_at, comms_messages.id) > (?, ?)", cursor_sent_at, cursor_id)
              .order(:sent_at, :id).limit(limit).to_a
          elsif params[:since].present?
            scope.where("comms_messages.sent_at >= ?", since).order(:sent_at, :id).limit(limit).to_a
          else
            scope.order(sent_at: :desc, id: :desc).limit(limit).to_a.reverse
          end
          next_cursor = (encode_cursor(messages.last) if messages.size == limit)
          render json: { chat: chat.as_comms_json, messages: messages.map(&:as_comms_json), next_cursor: next_cursor }
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

        def encode_cursor(message)
          Base64.urlsafe_encode64("#{message.sent_at.utc.iso8601(6)}|#{message.id}", padding: false)
        end

        def cursor
          sent_at, id = Base64.urlsafe_decode64(params[:after].to_s).split("|", 2)
          raise ArgumentError unless id.to_s.match?(/\A\d+\z/)

          [ Time.iso8601(sent_at.to_s), id.to_i ]
        rescue ArgumentError
          raise ActionController::BadRequest, "after must be a next_cursor value"
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
