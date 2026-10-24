module Api
  module V1
    module Comms
      class ChatsController < BaseController

        def index
          chats = @connection.comms_chats
            .order(Arel.sql("last_activity_at DESC NULLS LAST"), id: :desc)
            .limit(limit)
          render json: { chats: chats.map(&:as_comms_json) }
        end

      end
    end
  end
end
