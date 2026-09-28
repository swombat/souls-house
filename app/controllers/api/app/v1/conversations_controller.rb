module Api
  module App
    module V1
      class ConversationsController < BaseController

        # Kept, human-visible conversations, as in the web sidebar: active
        # first, then archived, each most recently updated first.
        def index
          account = find_account!(params[:account_id])
          chats = account.chats.kept.not_agent_only.includes(:account, :agents)
          render json: { conversations: (chats.active.latest + chats.archived.latest).map { |c| Presenter.conversation(c) } }
        end

      end
    end
  end
end
