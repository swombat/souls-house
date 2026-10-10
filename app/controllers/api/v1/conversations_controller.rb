module Api
  module V1
    class ConversationsController < BaseController

      include ApiConversationJson
      include ApiHumanConversation

      wrap_parameters false

      PAGE_SIZE = 100
      SEARCH_PAGE_SIZE = 50
      TITLE_MAX_LENGTH = 255
      MODEL_ID_MAX_LENGTH = 255
      LIST_FILTERS = %w[active archived deleted].freeze
      UPDATABLE_FIELDS = %w[title visual_tag_id model_id web_access].freeze
      # The web's chats#update also changes these; a resident's key may not.
      HUMAN_ONLY_FIELDS = %w[model_id web_access].freeze

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
        scope = listing_scope
        return if performed?

        chats = paginated_conversations(scope).limit(PAGE_SIZE + 1).to_a
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
            visual_tag: chat.visual_tag&.as_json,
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
        @destination = requested_account
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
          account: @destination,
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
      rescue ActiveRecord::RecordInvalid => error
        # A guest that departed between the account check and the insert is
        # refused by the seat lock; say so rather than raising.
        record = error.record
        seat_errors = record.respond_to?(:chat_agents) ? record.chat_agents.flat_map { |seat| seat.errors.full_messages } : []
        render json: { error: (seat_errors.presence || record.errors.full_messages).to_sentence }, status: :unprocessable_entity
      end

      # Top-level, atomic metadata changes; title-only clients keep working.
      def update
        chat = conversations_scope.kept.find(params[:id])
        changes = params.except(:controller, :action, :id, :account_id, :format).to_unsafe_h
        unless changes.any? && (changes.keys - UPDATABLE_FIELDS).empty?
          render json: { error: "Provide top-level #{UPDATABLE_FIELDS.to_sentence(last_word_connector: ", and/or ")}; no other fields are accepted" }, status: :unprocessable_entity
          return
        end
        if (changes.keys & HUMAN_ONLY_FIELDS).any?
          if current_api_agent
            render json: { error: "model_id and web_access can only be changed with a person's API key" }, status: :forbidden
            return
          end
          # As chats#update: the room's account must still be the person's,
          # and chats must be switched on.
          human_account!(chat.account)
          require_chats_feature!
          return if performed?
        end
        if changes.key?("model_id")
          model_id = changes["model_id"]
          unless model_id.is_a?(String) && model_id.strip.present? && model_id.length <= MODEL_ID_MAX_LENGTH && !model_id.include?("\0")
            render json: { error: "model_id must be nonblank text of at most #{MODEL_ID_MAX_LENGTH} characters, without NUL" }, status: :unprocessable_entity
            return
          end
        end
        if changes.key?("web_access") && ![ true, false ].include?(changes["web_access"])
          render json: { error: "web_access must be true or false" }, status: :unprocessable_entity
          return
        end
        if changes.key?("title")
          title = changes["title"]
          unless title.is_a?(String) && title.strip.present? && title.strip.length <= TITLE_MAX_LENGTH && !title.include?("\0")
            render json: { error: "title must be nonblank text of at most #{TITLE_MAX_LENGTH} characters, without NUL" }, status: :unprocessable_entity
            return
          end
          changes["title"] = title.strip
        end
        if changes.key?("visual_tag_id")
          tag_id = changes.delete("visual_tag_id")
          unless tag_id.nil? || (tag_id.is_a?(String) && tag_id.present?)
            render json: { error: "visual_tag_id must be a nonblank public ID string or null" }, status: :unprocessable_entity
            return
          end
          changes["visual_tag"] = VisualTag.resolve_for(chat.account, tag_id)
        end

        if chat.update(changes)
          render json: { conversation: conversation_json(chat) }
        else
          render json: { error: chat.errors.full_messages.to_sentence }, status: :unprocessable_entity
        end
      rescue ActiveRecord::InvalidForeignKey
        render json: {
          error: "This tag is no longer available. Refresh the palette and try again.",
          code: "visual_tag_unavailable"
        }, status: :conflict
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

        human_chats
      end

      # active (default) is what the API has always listed. archived and
      # deleted mirror the web sidebar (chats#index): archived rooms for any
      # current member, deleted ones only where the person can manage the
      # account. Both are person-only and need chats switched on.
      def listing_scope
        filter = params[:filter].presence || "active"
        unless LIST_FILTERS.include?(filter)
          render json: { error: "filter must be one of #{LIST_FILTERS.join(", ")}" }, status: :unprocessable_entity
          return
        end
        return conversations_scope.kept.active if filter == "active"

        require_human_actor!
        require_chats_feature! unless performed?
        return if performed?

        scope = member_chats
        return scope.kept.archived if filter == "archived"

        if spans_accounts?
          # An unnarrowed OAuth token: only the accounts the person may manage.
          manageable = current_api_user.confirmed_accounts.select { |account| account.manageable_by?(current_api_user) }
          return scope.discarded.where(account_id: manageable.map(&:id))
        end
        unless human_account!(current_api_account).manageable_by?(current_api_user)
          render json: { error: "Only someone who can manage this account can list deleted conversations" }, status: :forbidden
          return
        end
        scope.discarded
      end

      # An OAuth token without account_id reaches every enabled account the
      # person belongs to; otherwise the request names one account.
      def spans_accounts?
        app_token_request? && params[:account_id].blank?
      end

      # human_chats, but only where the person is still a confirmed member of
      # an enabled account: an account key whose person has left, or whose
      # account is disabled, lists nothing (404).
      def member_chats
        return human_chats if spans_accounts?

        human_account!(current_api_account)
        human_chats
      end

      def paginated_conversations(listed)
        scope = listed.includes(:visual_tag).reorder(updated_at: :desc, id: :desc)
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
        # The safeguard check is a network call: run it before the transaction.
        safeguard_check = SafeguardConversationPost.check(agent: current_api_agent, content: params[:message])

        # In a guest account, the creator's own seat is admitted under the
        # membership lock (ChatAgent#agent_takes_part_in_account), like any seat.
        @destination.chats.transaction do
          chat = @destination.chats.new(
            model_id: params[:model_id] || current_api_agent.model_id || "openrouter/auto",
            title: params[:title],
            manual_responses: true,
            initiated_by_agent: current_api_agent,
            initiation_reason: params[:reason]
          )
          chat.agent_ids = agent_ids
          chat.save!

          if params[:message].present?
            opening = chat.messages.build(
              role: "assistant",
              agent: current_api_agent,
              content: params[:message]
            )
            # An @Name tag of an invited resident hands off to them, as in any post.
            opening.handoff_recipient_ids = []
            SafeguardConversationPost.save(opening, check: safeguard_check) or
              raise ActiveRecord::RecordInvalid, opening
          end

          chat
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
        agents = @destination.conversation_agents.eligible_for_conversation.where(id: real_ids)

        if agents.length != obfuscated_ids.length
          missing = obfuscated_ids.length - agents.length
          raise ActiveRecord::RecordNotFound, "#{missing} agent(s) not found or inactive"
        end

        agents.pluck(:id)
      end

    end
  end
end
