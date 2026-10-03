module Api
  module V1
    class ConversationsController < BaseController

      PAGE_SIZE = 100
      SEARCH_PAGE_SIZE = 50
      TITLE_MAX_LENGTH = 255

      def search
        response.headers["Cache-Control"] = "no-store"
        query = params[:query]
        unless query.is_a?(String) && query.present? && query.length <= 200 && !query.include?("\0")
          render json: { error: "query must be nonblank text of at most 200 characters, without NUL" }, status: :unprocessable_entity
          return
        end
        unless params[:cursor].nil? || params[:cursor].is_a?(String)
          render json: { error: "cursor must be text" }, status: :unprocessable_entity
          return
        end

        messages = Message.kept.where(chat_id: conversations_scope.kept.active.select(:id))
                          .where(role: %w[user assistant], progress_message: false)
                          .where(literal_content_match(query))
        if params[:cursor].present?
          cursor = messages.find(params[:cursor])
          messages = messages.where("messages.id < ?", cursor.id)
        end
        results = messages.includes(:chat, :user, :agent).reorder(id: :desc).limit(SEARCH_PAGE_SIZE + 1).to_a
        next_cursor = results.length > SEARCH_PAGE_SIZE ? results[SEARCH_PAGE_SIZE - 1].to_param : nil

        payload = {
          messages: results.first(SEARCH_PAGE_SIZE).map { |message| search_result_json(message, query) },
          next_cursor: next_cursor
        }
        if results.empty?
          payload[:guidance] = "No literal match on this page. Try a shorter distinctive fragment or check capitalization; an empty result does not mean an exchange never happened."
        end
        render json: payload
      end

      def index
        chats = paginated_conversations.limit(PAGE_SIZE + 1).to_a
        next_cursor = chats.length > PAGE_SIZE ? chats[PAGE_SIZE - 1].to_param : nil
        chats = chats.first(PAGE_SIZE)

        render json: {
          conversations: chats.map { |chat| conversation_json(chat) },
          next_cursor: next_cursor
        }
      end

      def show
        chat = conversations_scope.find(params[:id])
        render json: {
          conversation: {
            id: chat.to_param,
            title: chat.title_or_default,
            model: chat.model_label,
            group_chat: chat.group_chat?,
            agents: chat.group_chat? ? chat.agents.map { |a| { id: a.to_param, name: a.name } } : [],
            created_at: chat.created_at.iso8601,
            updated_at: chat.updated_at.iso8601,
            transcript: chat.transcript_for_api(after_message_id: resolved_after_message_id, since: params[:since])
          }
        }
      end

      def create
        agent_ids = resolve_agent_ids
        return if performed?

        if current_api_agent
          chat = create_agent_scoped_conversation!(agent_ids)

          render json: {
            conversation: {
              id: chat.to_param,
              title: chat.title_or_default,
              group_chat: chat.group_chat?,
              agents: chat.agents.map { |a| { id: a.to_param, name: a.name } },
              created_at: chat.created_at.iso8601
            }
          }, status: :created
          return
        end

        chat_attrs = {
          account: current_api_account,
          model_id: params[:model_id] || "openrouter/auto",
          title: params[:title],
          manual_responses: true
        }

        chat = Chat.create_with_message!(
          chat_attrs,
          message_content: params[:message],
          user: current_api_user,
          agent_ids: agent_ids
        )

        render json: {
          conversation: {
            id: chat.to_param,
            title: chat.title_or_default,
            group_chat: chat.group_chat?,
            agents: chat.group_chat? ? chat.agents.map { |a| { id: a.to_param, name: a.name } } : [],
            created_at: chat.created_at.iso8601
          }
        }, status: :created
      end

      # Rename only. The title is read from the top level; any other shape
      # (for example a nested {"conversation": {...}}) gets 422 rather than a
      # silent success, so a caller can never mistake a no-op for a rename.
      def update
        chat = conversations_scope.kept.find(params[:id])
        title = params[:title]

        unless title.is_a?(String) && title.strip.present? && title.strip.length <= TITLE_MAX_LENGTH
          render json: { error: "Provide a top-level title: nonblank text of at most #{TITLE_MAX_LENGTH} characters" },
                 status: :unprocessable_entity
          return
        end
        title = title.strip

        if chat.update(title: title)
          render json: { conversation: conversation_json(chat) }
        else
          render json: { error: chat.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end
      end

      private

      def literal_content_match(query)
        # A named bind lets the existing query filter redact SQL logs too.
        attribute = ActiveRecord::Relation::QueryAttribute.new("query", query, ActiveRecord::Type::String.new)
        Arel::Nodes::NamedFunction.new("strpos", [
          Message.arel_table[:content], Arel::Nodes::BindParam.new(attribute)
        ]).gt(0)
      end

      def search_result_json(message, query)
        offset = [ message.content.index(query) - 80, 0 ].max
        {
          conversation_id: message.chat.to_param,
          message_id: message.to_param,
          authored_at: message.created_at.iso8601,
          author: message.agent || message.user ? message.author_name : message.role.titleize,
          role: message.role,
          snippet: message.content[offset, 400],
          snippet_offset: offset,
          detail_path: api_v1_conversation_path(message.chat)
        }
      end

      def conversations_scope
        return current_api_agent.chats if current_api_agent

        current_api_account.chats
      end

      def paginated_conversations
        scope = conversations_scope.kept.active.reorder(updated_at: :desc, id: :desc)
        return scope if params[:cursor].blank?

        cursor = conversations_scope.find(params[:cursor])
        scope.where(
          "chats.updated_at < :updated_at OR (chats.updated_at = :updated_at AND chats.id < :id)",
          updated_at: cursor.updated_at,
          id: cursor.id
        )
      end

      def resolved_after_message_id
        return nil if params[:after_message_id].blank?

        Message.decode_id(params[:after_message_id])
      end

      def create_agent_scoped_conversation!(invited_agent_ids)
        agent_ids = ([ current_api_agent.id ] + invited_agent_ids).uniq
        opening_message = nil

        current_api_account.chats.transaction do
          chat = current_api_account.chats.new(
            model_id: params[:model_id] || current_api_agent.model_id || "openrouter/auto",
            title: params[:title],
            manual_responses: true,
            initiated_by_agent: current_api_agent,
            initiation_reason: params[:reason]
          )
          chat.agent_ids = agent_ids
          chat.save!

          if params[:message].present?
            opening_message = chat.messages.create!(
              role: "assistant",
              agent: current_api_agent,
              content: params[:message]
            )
          end

          chat
        end.tap do |chat|
          # Match Chat.initiate_by_agent! without notifying message-less rooms.
          current_api_agent.notify_subscribers!(opening_message, chat) if opening_message
        end
      end

      def resolve_agent_ids
        ids = params[:agent_ids]
        return [] if current_api_agent && ids.nil?

        unless ids.is_a?(Array) && ids.all? { |id| id.is_a?(String) && id.present? } &&
            (current_api_agent || ids.any?)
          render json: { error: "agent_ids must be an array of nonblank resident IDs; account keys must select at least one resident" },
                 status: :unprocessable_entity
          return
        end

        obfuscated_ids = ids.uniq
        real_ids = obfuscated_ids.filter_map { |oid| Agent.decode_id(oid) }
        agents = current_api_account.conversation_agents.eligible_for_conversation.where(id: real_ids)

        if agents.length != obfuscated_ids.length
          missing = obfuscated_ids.length - agents.length
          raise ActiveRecord::RecordNotFound, "#{missing} agent(s) not found or inactive"
        end

        agents.pluck(:id)
      end

      def conversation_json(chat)
        {
          id: chat.to_param,
          title: chat.title_or_default,
          summary: chat.summary,
          summary_stale: chat.summary_stale?,
          model: chat.model_label,
          group_chat: chat.group_chat?,
          message_count: chat.message_count,
          updated_at: chat.updated_at.iso8601
        }
      end

    end
  end
end
