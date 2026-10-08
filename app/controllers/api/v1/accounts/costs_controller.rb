module Api
  module V1
    module Accounts
      # Estimated running costs, from the same reports the web shows: the
      # account's (accounts/costs#show), one resident's (the resident settings
      # page) and one conversation's (the conversation's cost breakdown). Any
      # member may read them, as on the web.
      class CostsController < BaseController

        include ApiAccountAdministration

        before_action :set_administered_account, only: :show
        before_action -> { require_feature_enabled!(:agents) }, only: %i[show agent]
        before_action -> { require_feature_enabled!(:chats) }, only: :conversation

        def show
          render json: { cost_report: AccountInteractionCostReport.new(account: @account).call }
        end

        # Residents hosted in this account (not guests), as AgentsController#edit finds them.
        def agent
          agent = Agent.where(account: administrable_accounts).find(params[:agent_id])
          administer!(agent.account)
          render json: {
            agent: { id: agent.to_param, name: agent.name },
            cost_report: AgentInteractionCostReport.new(agent: agent).call
          }
        end

        # Including deleted conversations, as ChatsController#show finds them.
        def conversation
          chat = Chat.with_discarded.where(account: administrable_accounts).find(params[:conversation_id])
          administer!(chat.account)
          render json: {
            conversation: { id: chat.to_param, title: chat.title },
            cost_breakdown: ChatUsageReport.new(chat: chat).call
          }
        end

      end
    end
  end
end
