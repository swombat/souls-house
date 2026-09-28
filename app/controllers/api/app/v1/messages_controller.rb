module Api
  module App
    module V1
      # Messages in a conversation. History pages (index) are for scrolling
      # back and are not a sync checkpoint: reconciliation goes through
      # ChangesController. Writes follow the web's rules through the same
      # paths (PostFromHuman, discard), with the sends made retry-safe by a
      # client-generated identity (ADR 0004).
      class MessagesController < BaseController

        DEFAULT_LIMIT = 30
        MAX_LIMIT = 100
        CLIENT_MESSAGE_ID_FORMAT = /\A[A-Za-z0-9_-]{8,64}\z/

        before_action :set_conversation
        before_action :set_message, only: [ :update, :destroy ]
        before_action :authorize_message_modification, only: [ :update, :destroy ]

        # Each page is the newest `limit` kept messages before `before`,
        # returned oldest first (chronological).
        def index
          limit = bounded_integer(:limit, default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT) or return
          messages = @chat.messages_page(before_id: params[:before], limit: limit)
          has_more = messages.any? && @chat.messages.kept.where("messages.id < ?", messages.first.id).exists?

          render json: {
            messages: messages.map { |m| Presenter.message(m, viewer: current_user) },
            has_more: has_more,
            oldest_id: messages.first&.to_param
          }
        end

        # 201 on first acceptance; 200 with the message's current state (or its
        # discard marker) when the same identity and payload come again; 409 when
        # the identity was already used for a different payload. A retry is
        # answered before anything else is checked, so it never wakes a resident
        # twice, even if the conversation has since been archived.
        def create
          client_message_id = params[:client_message_id].to_s
          content = params[:content]
          unless client_message_id.match?(CLIENT_MESSAGE_ID_FORMAT)
            return render_error(:unprocessable_entity, "invalid_parameter", "client_message_id must be 8-64 characters of A-Z, a-z, 0-9, _ or -", { parameter: "client_message_id" })
          end
          unless content.is_a?(String) && content.present?
            return render_error(:unprocessable_entity, "invalid_parameter", "content is required", { parameter: "content" })
          end

          existing = find_submission(client_message_id)
          return render_retry(existing, content) if existing

          unless @chat.respondable?
            return render_error(:unprocessable_entity, "conversation_not_respondable", "This conversation is archived and cannot receive new messages")
          end

          result = Messages::PostFromHuman.new(chat: @chat, user: current_user, content: content, client_message_id: client_message_id)
            .call(on_persisted: ->(message) { audit("create_message", message, content: content, client_message_id: client_message_id) })

          if result.created?
            render json: { message: Presenter.message(result.message, viewer: current_user) }, status: :created
          elsif result.duplicate?
            # A concurrent twin that commits before this save is validated trips
            # the web's repeat guard (same content as the last message) before
            # the unique index can; it is still a retry, not a refusal.
            if (twin = find_submission(client_message_id))
              return render_retry(twin, content)
            end

            render_error :unprocessable_entity, "duplicate_message", "This is the same as the conversation's last message"
          else
            render_error :unprocessable_entity, "invalid_message", result.message.errors.full_messages.to_sentence
          end
        rescue ActiveRecord::RecordNotUnique
          # A concurrent request with the same identity committed first; its
          # transaction woke the residents, this one rolled back entirely.
          existing = find_submission(client_message_id) or raise
          render_retry(existing, content)
        end

        def update
          content = params[:content]
          unless content.is_a?(String) && content.present?
            return render_error(:unprocessable_entity, "invalid_parameter", "content is required", { parameter: "content" })
          end

          old_content = @message.content
          if @message.update(content: content)
            audit("update_message", @message, old_content: old_content, new_content: @message.content)
            render json: { message: Presenter.message(@message, viewer: current_user) }
          else
            render_error :unprocessable_entity, "invalid_message", @message.errors.full_messages.to_sentence
          end
        end

        # Delete is discard (ADR 0001): the content stays, hidden. Repeating it
        # is a no-op that returns the same marker.
        def destroy
          unless @message.discarded?
            audit("delete_message", @message, content: @message.content)
            @message.discard!
          end
          render json: { message: Presenter.message(@message, viewer: current_user) }
        end

        private

        def set_conversation
          @chat = find_conversation!(params[:conversation_id])
        end

        # Only delete may find an already-discarded message, so a repeat is a
        # no-op; an edit of a discarded message is 404.
        def set_message
          scope = action_name == "destroy" ? @chat.messages : @chat.messages.kept
          @message = scope.find(params[:id])
        end

        # The author's own human messages only. Unlike the web there is no
        # site-admin override, as for reads (ADR 0003).
        def authorize_message_modification
          return if @message.role == "user" && @message.user_id == current_user.id

          render_error :forbidden, "forbidden", "Only the author can change this message"
        end

        def find_submission(client_message_id)
          @chat.messages.find_by(user: current_user, client_message_id: client_message_id)
        end

        def render_retry(message, content)
          if message.submission_digest == Messages::PostFromHuman.submission_digest(content: content)
            render json: { message: Presenter.message(message, viewer: current_user) }, status: :ok
          else
            render_error :conflict, "idempotency_conflict", "client_message_id was already used for a different message",
                         { message_id: message.to_param }
          end
        end

      end
    end
  end
end
