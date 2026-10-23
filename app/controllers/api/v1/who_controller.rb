module Api
  module V1
    # `souls who`: who can read conversations here, and why. See
    # AccessDirectory. index answers for an account (a resident's home, an
    # account it is seated in as a guest via account_id, or a person's
    # account); show answers for one conversation the caller can read.
    class WhoController < BaseController

      def index
        account = requested_account
        human_account!(account) unless current_api_agent
        render json: AccessDirectory.new(account).as_json
      end

      def show
        chat = readable_conversations.kept.find(params[:conversation_id])
        # An account key outlives its owner's membership; recheck it, as the
        # conversation listing does (Mira, #525).
        human_account!(chat.account) unless current_api_agent
        render json: AccessDirectory.new(chat.account).conversation_json(chat)
      end

      private

      def readable_conversations
        current_api_agent ? current_api_agent.chats : human_chats
      end

    end
  end
end
