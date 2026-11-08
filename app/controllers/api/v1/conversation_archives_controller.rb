module Api
  module V1
    # chats/archives. A person's credential: any member may archive or
    # unarchive. A resident key: a conversation in its home account that it
    # sits in, and only when nothing in it is still owed. Archiving dismisses
    # open reply expectations and a commitment due in an archived chat waits
    # silently, so the resident door refuses (409, with the list) while the
    # chat has an open reply expectation, a scheduled commitment, or an
    # activated one whose wake is still in custody, anyone's. Commitments are
    # listed by their shared headline only, never their private text.
    class ConversationArchivesController < BaseController

      include ApiConversationJson
      include ApiHumanConversation

      before_action :require_chats_feature!
      before_action :set_chat

      # POST /api/v1/conversations/:conversation_id/archive
      def create
        if current_api_agent
          return if refuse_while_owed
          return render(json: { conversation: conversation_json(@chat) }) if @chat.archived?

          @chat.archive!
          audit_resident_action("archive_chat")
        else
          @chat.archive!
          audit_human_action("archive_chat", @chat, account: @chat.account)
        end
        render json: { conversation: conversation_json(@chat) }
      end

      # DELETE /api/v1/conversations/:conversation_id/archive
      def destroy
        if current_api_agent
          if @chat.archived?
            @chat.unarchive!
            audit_resident_action("unarchive_chat")
          end
        else
          @chat.unarchive!
          audit_human_action("unarchive_chat", @chat, account: @chat.account)
        end
        render json: { conversation: conversation_json(@chat) }
      end

      private

      def set_chat
        @chat = current_api_agent ? resident_chat! : human_chat!
      end

      # The resident's home account only, and a conversation it is in.
      def resident_chat!
        current_api_agent.chats.kept.where(account_id: current_api_agent.account_id).find(params[:conversation_id])
      end

      def refuse_while_owed
        expectations = ReplyExpectation.joins(:message).state_open
          .where(messages: { chat_id: @chat.id, discarded_at: nil }).includes(:user, :message)
        # Scheduled ones made here, and ones already activated into this chat
        # whose wake is still held or retrying (a claim or retry checks
        # activation_chat.respondable?, so archiving would strand them).
        commitments = Commitment.scheduled.where(source_chat_id: @chat.id)
          .or(Commitment.wake_in_custody.where(activation_chat_id: @chat.id))
          .includes(:agent).order(:due_at)
        return false if expectations.none? && commitments.none?

        render json: {
          error: "This conversation still has something owed in it; archiving would dismiss or silence it. Answer, dismiss or cancel these first.",
          code: "conversation_has_pending_work",
          open_reply_expectations: expectations.map { |e|
            { message_id: e.message.to_param, awaiting: e.user&.display_name }
          },
          scheduled_commitments: commitments.map { |c|
            { id: c.to_param, resident: c.agent.name, due_at: c.due_at.iso8601, status: c.status, headline: c.headline }
          }
        }, status: :conflict
        true
      end

      def audit_resident_action(action)
        AuditLog.create!(user: nil, account: @chat.account, action:, auditable: @chat,
          data: { by: "resident", agent_id: current_api_agent.id, api_key_id: @current_api_key&.id },
          ip_address: request.remote_ip, user_agent: request.user_agent)
      end

    end
  end
end
