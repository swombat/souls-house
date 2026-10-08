module Api
  module V1
    module Accounts
      # Estimated running costs, from the same reports the web shows: the
      # account's (accounts/costs#show), one resident's (the resident settings
      # page) and one conversation's (the conversation's cost breakdown). Any
      # member may read them, as on the web.
      class CostsController < BaseController

        include ApiAccountAdministration

        before_action -> { require_feature_enabled!(:agents) }, only: %i[show agent]
        before_action -> { require_feature_enabled!(:chats) }, only: :conversation

        def show
          render json: { cost_report: AccountInteractionCostReport.new(account: @account).call }
        end

        # Residents hosted in this account (not guests), as AgentsController#edit finds them.
        def agent
          agent = @account.agents.find(params[:agent_id])
          render json: {
            agent: { id: agent.to_param, name: agent.name },
            cost_report: AgentInteractionCostReport.new(agent: agent).call
          }
        end

        # Including deleted conversations, as ChatsController#show finds them.
        def conversation
          chat = @account.chats.with_discarded.find(params[:conversation_id])
          render json: {
            conversation: { id: chat.to_param, title: chat.title },
            cost_breakdown: ChatUsageReport.new(chat: chat).call
          }
        end

      end
    end
  end
end
