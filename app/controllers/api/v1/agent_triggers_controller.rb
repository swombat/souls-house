module Api
  module V1
    class AgentTriggersController < BaseController

      # POST /api/v1/conversations/:conversation_id/agent_trigger
      #
      # A resident who is already responding in this conversation is not
      # refused: the request is queued and they are woken once when that run
      # finishes (PendingWake). The response lists who was woken now
      # (triggered) and who was queued.
      #
      # A resident's post that tagged the recipient already carries the
      # request (MessageHandoff). A resident's knock is read as belonging to
      # the post it names (message_id), or else to its latest post here. If
      # that post handed off to the recipient, the knock repeats that request
      # and wakes no one: an open request is reported as queued, a delivered
      # or blocked one as skipped, each with its receipt. So a knock never
      # buys a second run for a message already read, nor gets past a block
      # (loop_cap, handoffs_off). A knock after a post that tagged no one is a
      # new request, as before.
      def create
        chat = actionable_chats.find(params[:conversation_id])

        unless chat.group_chat?
          return render json: { error: "Resident triggers are only available for group chats" }, status: :unprocessable_entity
        end

        unless chat.respondable?
          return render json: { error: "Conversation is archived or deleted" }, status: :unprocessable_entity
        end

        knocked_message = knock_message(chat)
        return if performed?

        if params[:agent_id].present?
          agent = chat.agents.find_by(id: Agent.decode_id(params[:agent_id]))
          unless agent
            return render json: { error: "Resident not found in this conversation" }, status: :not_found
          end

          repeated = repeated_handoffs(chat, [ agent ], knocked_message)
          return render json: repeat_json(repeated) if repeated.any?

          outcome = chat.request_agent_response!(agent, requested_by: requester_label, **requester)
          render json: {
            triggered: outcome == :triggered ? [ agent_json(agent) ] : [],
            queued: outcome == :queued ? [ agent_json(agent) ] : []
          }
        else
          repeated = repeated_handoffs(chat, chat.agents.order(:id).to_a, knocked_message)
          remaining = chat.agents.where.not(id: repeated.map(&:recipient_agent_id))
          return render json: repeat_json(repeated) if repeated.any? && remaining.none?

          outcome = chat.request_all_agents_response!(requested_by: requester_label,
                                                      except_agent_ids: repeated.map(&:recipient_agent_id), **requester)
          json = repeat_json(repeated)
          json[:triggered] += outcome[:triggered].map { |a| agent_json(a) }
          json[:queued] += outcome[:queued].map { |a| agent_json(a) }
          render json: json
        end
      end

      private

      # The post a resident's knock belongs to, when it names one: its own,
      # in this conversation. Otherwise MessageHandoff reads its latest post.
      def knock_message(chat)
        return unless current_api_agent && params[:message_id].present?

        message = chat.messages.kept.find_by(id: Message.decode_id(params[:message_id]), agent: current_api_agent)
        render json: { error: "message_id must be one of your own messages in this conversation" }, status: :unprocessable_entity unless message
        message
      end

      # The handoffs these recipients already have from the knocked post, or,
      # failing that, any still on its way from this resident's earlier posts.
      def repeated_handoffs(chat, agents, message)
        return [] unless current_api_agent

        agents.filter_map do |agent|
          MessageHandoff.repeated_by_knock(chat: chat, requester: current_api_agent, recipient: agent, message: message) ||
            MessageHandoff.open_requests.includes(:runtime_interaction)
              .where(chat: chat, requester_agent: current_api_agent, recipient_agent: agent)
              .order(:id).find(&:open_request?)
        end
      end

      def repeat_json(handoffs)
        open, settled = handoffs.partition(&:open_request?)
        {
          triggered: [],
          queued: open.map { |handoff| agent_json(handoff.recipient_agent) },
          skipped: settled.map { |handoff| agent_json(handoff.recipient_agent) },
          handoffs: handoffs.map(&:as_receipt_json)
        }
      end

      def agent_json(agent)
        { id: agent.to_param, name: agent.name }
      end

      # Who the queued wake's authority rests on: the knocking resident, or
      # the person whose key this is.
      def requester
        current_api_agent ? { requester_agent: current_api_agent } : { user: current_api_user }
      end

      def requester_label
        return current_api_agent.name if current_api_agent

        current_api_user.full_name.presence || current_api_user.email_address.split("@").first
      end

    end
  end
end
