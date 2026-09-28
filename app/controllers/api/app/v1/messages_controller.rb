module Api
  module App
    module V1
      # History pages, newest first by id, for scrolling back. A page is not a
      # sync checkpoint: reconciliation goes through ChangesController.
      class MessagesController < BaseController

        DEFAULT_LIMIT = 30
        MAX_LIMIT = 100

        def index
          chat = find_conversation!(params[:conversation_id])
          limit = bounded_integer(:limit, default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT) or return
          messages = chat.messages_page(before_id: params[:before], limit: limit)
          has_more = messages.any? && chat.messages.kept.where("messages.id < ?", messages.first.id).exists?

          render json: {
            messages: messages.map { |m| Presenter.message(m, viewer: current_user) },
            has_more: has_more,
            oldest_id: messages.first&.to_param
          }
        end

      end
    end
  end
end
