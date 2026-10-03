module Api
  module App
    module V1
      class ConversationsController < BaseController

        CLIENT_CONVERSATION_ID_FORMAT = /\A[A-Za-z0-9_-]{8,64}\z/

        before_action :set_conversation, only: [ :invoke, :activity ]

        # Kept conversations, as in the web sidebar: active
        # first, then archived, each most recently updated first.
        def index
          account = find_account!(params[:account_id])
          chats = account.chats.kept.includes(:account, :agents)
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
        # web's trigger does, keyed by client_invocation_id (#94 B,
        # keyed-invoke extension). A new invocation is accepted and reserved in
        # one transaction and answers 202 with its dispatch. The same key with
        # the same request answers 202 with that invocation's recorded outcome,
        # whatever it is now (reserved, running, finished, cancelled, expired);
        # it never starts another run, which is how the app reads an
        # invocation's status. The same key with a different request is 409.
        #
        # A retry is judged before anything a new invocation would need (live
        # activity, eligibility, busy); account access is checked every time.
        # A new invocation is 503 while live activity is off, 409 while a
        # target is already responding (nothing is written), 409 with its
        # availability code for a resident who can't run, 404 for a resident
        # outside the conversation, and 422 when the conversation can't be
        # invoked.
        def invoke
          client_invocation_id = params[:client_invocation_id].to_s
          unless client_invocation_id.match?(CLIENT_CONVERSATION_ID_FORMAT)
            return render_error(:unprocessable_entity, "invalid_parameter", "client_invocation_id must be 8-64 characters of A-Z, a-z, 0-9, _ or -", { parameter: "client_invocation_id" })
          end
          agent_id = requested_invoke_agent_id
          digest = MessageDispatch.invocation_digest(agent_id)

          existing = invocation(client_invocation_id)
          return render_invocation_retry(existing, digest) if existing

          unless AgentRuntimeInteraction.live_activity_enabled?
            return render_error(:service_unavailable, "live_activity_unavailable",
                                "Residents cannot be asked to respond right now; nothing was started", { retryable: true })
          end
          agent = agent_id && @chat.agents.find(agent_id)
          check_invokable!(agent)

          dispatch = MessageDispatch.invoke!(chat: @chat, user: current_user, client_invocation_id: client_invocation_id, agent: agent)
          render json: { invocation: dispatch.as_app_json }, status: :accepted
        rescue ActiveRecord::RecordNotUnique
          # A concurrent request with the same key committed first.
          existing = invocation(client_invocation_id) or raise
          render_invocation_retry(existing, digest)
        rescue Chat::AlreadyResponding, Agent::RuntimeAvailability::Unavailable, ArgumentError, MessageDispatch::InvocationRefused => e
          # A same-key twin that committed while this request waited on the
          # chat lock makes its own run look busy here: it is a retry.
          if (existing = client_invocation_id.presence && invocation(client_invocation_id))
            return render_invocation_retry(existing, digest)
          end

          case e
          when Chat::AlreadyResponding then render_error :conflict, "already_responding", e.message
          when Agent::RuntimeAvailability::Unavailable then render_error :conflict, e.code, e.message
          else render_error :unprocessable_entity, "not_invokable", e.message
          end
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
          agents = account.conversation_agents.eligible_for_conversation.where(id: agent_ids).to_a
          return agents if agents.size == agent_ids.size

          render_invalid_agent_ids
        end

        # The named resident as a database id, nil for everyone. An id that
        # names no resident is 404, as a resident outside the conversation is.
        def requested_invoke_agent_id
          return nil if params[:agent_id].blank?

          Integer(Agent.decode_id(params[:agent_id].to_s), exception: false) || raise(ActiveRecord::RecordNotFound)
        rescue Hashids::InputError
          raise ActiveRecord::RecordNotFound
        end

        def invocation(client_invocation_id)
          MessageDispatch.find_by(kind: "invoke", chat: @chat, user: current_user, client_invocation_id: client_invocation_id)
        end

        # The web trigger's checks for a new request, except busy, which is
        # decided under the chat lock where the run is reserved.
        def check_invokable!(agent)
          raise ArgumentError, "This chat does not support manual responses" unless @chat.manual_responses?
          raise ArgumentError, "This conversation is archived or deleted" unless @chat.respondable?
          if agent
            agent.require_conversation_runtime!
          else
            raise ArgumentError, "No agents in this conversation" if @chat.agents.empty?
            unless @chat.agents.any?(&:eligible_for_conversation?)
              raise Agent::RuntimeAvailability::Unavailable.new("No available agents in this conversation", code: "no_available_agents")
            end
          end
        end

        def render_invocation_retry(dispatch, digest)
          if dispatch.request_digest == digest
            render json: { invocation: dispatch.as_app_json }, status: :accepted
          else
            render_error :conflict, "idempotency_conflict", "client_invocation_id was already used for a different request"
          end
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
