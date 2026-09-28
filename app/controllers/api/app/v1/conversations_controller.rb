module Api
  module App
    module V1
      class ConversationsController < BaseController

        CLIENT_CONVERSATION_ID_FORMAT = /\A[A-Za-z0-9_-]{8,64}\z/

        before_action :set_conversation, only: [ :invoke, :activity ]

        # Kept, human-visible conversations, as in the web sidebar: active
        # first, then archived, each most recently updated first.
        def index
          account = find_account!(params[:account_id])
          chats = account.chats.kept.not_agent_only.includes(:account, :agents)
          render json: { conversations: (chats.active.latest + chats.archived.latest).map { |c| Presenter.conversation(c) } }
        end

        # A new, empty conversation with the residents named in agent_ids
        # (#94 B, step 4b-iii). The first message goes through messages#create,
        # so it is retry-safe and wakes whoever it mentions like any other send.
        # Retry-safe the same way as a send: 201, then 200 for the same identity
        # and payload, 409 for the same identity with a different payload.
        def create
          account = find_account!(params[:account_id])
          client_conversation_id = params[:client_conversation_id].to_s
          unless client_conversation_id.match?(CLIENT_CONVERSATION_ID_FORMAT)
            return render_error(:unprocessable_entity, "invalid_parameter", "client_conversation_id must be 8-64 characters of A-Z, a-z, 0-9, _ or -", { parameter: "client_conversation_id" })
          end
          title = params[:title]
          unless title.nil? || title.is_a?(String)
            return render_error(:unprocessable_entity, "invalid_parameter", "title must be a string", { parameter: "title" })
          end
          agent_ids = requested_agent_ids or return
          title = title.to_s.strip.presence
          digest = creation_digest(agent_ids, title)

          # A retry is judged against what was originally submitted, not
          # against who could join a new conversation today: a resident
          # deactivated since must not turn a retry into a refusal.
          existing = account.chats.find_by(client_conversation_id: client_conversation_id)
          return render_retry(existing, digest) if existing

          agents = eligible_agents(account, agent_ids) or return
          chat = Chat.transaction do
            Chat.create_with_message!(
              { account: account, title: title, manual_responses: true,
                client_conversation_id: client_conversation_id, creation_digest: digest },
              agent_ids: agents.map(&:id)
            ).tap { |created| audit("create_chat", created, title: title, client_conversation_id: client_conversation_id) }
          end
          render json: { conversation: Presenter.conversation(chat) }, status: :created
        rescue ActiveRecord::RecordNotUnique
          # A concurrent request with the same identity committed first.
          existing = account.chats.find_by(client_conversation_id: client_conversation_id) or raise
          render_retry(existing, digest)
        end

        # Asks one resident (agent_id) or all of them to respond now, as the
        # web's trigger does. 202: the response arrives as messages and shows
        # in activity. 409 while one is already responding.
        def invoke
          if params[:agent_id].present?
            @chat.trigger_agent_response!(@chat.agents.find(params[:agent_id]))
          else
            @chat.trigger_all_agents_response!
          end
          head :accepted
        rescue Chat::AlreadyResponding => e
          render_error :conflict, "already_responding", e.message
        rescue Agent::RuntimeAvailability::Unavailable => e
          render_error :conflict, e.code, e.message
        rescue ArgumentError => e
          render_error :unprocessable_entity, "not_invokable", e.message
        end

        # The conversation's recent resident runs, oldest first.
        def activity
          render json: { activity: @chat.activity_timeline.map { |interaction| Presenter.activity(interaction) } }
        end

        private

        def set_conversation
          @chat = find_conversation!(params[:id])
        end

        # The submitted residents as database ids, sorted, or nil after a 422.
        def requested_agent_ids
          ids = Array(params[:agent_ids]).map(&:to_s).reject(&:blank?).uniq
          decoded = ids.map { |id| Integer(Agent.decode_id(id), exception: false) }
          return decoded.uniq.sort if ids.any? && decoded.none?(&:nil?)

          render_invalid_agent_ids
        rescue Hashids::InputError
          render_invalid_agent_ids
        end

        # Only a new conversation checks who may join one.
        def eligible_agents(account, agent_ids)
          agents = account.agents.eligible_for_conversation.where(id: agent_ids).to_a
          return agents if agents.size == agent_ids.size

          render_invalid_agent_ids
        end

        def render_invalid_agent_ids
          render_error :unprocessable_entity, "invalid_parameter", "agent_ids must name residents of this account who can join a conversation", { parameter: "agent_ids" }
          nil
        end

        def creation_digest(agent_ids, title)
          "v1:" + Digest::SHA256.hexdigest({ agent_ids: agent_ids, title: title }.to_json)
        end

        # A conversation deleted since is gone for the retry as for any read.
        def render_retry(chat, digest)
          raise ActiveRecord::RecordNotFound if chat.discarded?

          if chat.creation_digest == digest
            render json: { conversation: Presenter.conversation(chat) }, status: :ok
          else
            render_error :conflict, "idempotency_conflict", "client_conversation_id was already used for a different conversation",
                         { conversation_id: chat.to_param }
          end
        end

      end
    end
  end
end
