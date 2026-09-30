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
        MAX_ATTACHMENTS = 10

        before_action :set_conversation
        before_action :set_message, only: [ :update, :destroy, :dispatch_status ]
        before_action :authorize_message_modification, only: [ :update, :destroy, :dispatch_status ]

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
        #
        # attachment_ids are signed ids from uploads#create for this
        # conversation, in display order. The upload finishing is not the send
        # (ADR 0005): each is checked here, and a file not yet in storage is a
        # retryable 422 with nothing saved.
        def create
          client_message_id = params[:client_message_id].to_s
          content = params[:content]
          attachment_ids = params[:attachment_ids]
          unless client_message_id.match?(CLIENT_MESSAGE_ID_FORMAT)
            return render_error(:unprocessable_entity, "invalid_parameter", "client_message_id must be 8-64 characters of A-Z, a-z, 0-9, _ or -", { parameter: "client_message_id" })
          end
          unless attachment_ids.nil? || (attachment_ids.is_a?(Array) && attachment_ids.all?(String) && attachment_ids.size.between?(1, MAX_ATTACHMENTS))
            return render_error(:unprocessable_entity, "invalid_parameter", "attachment_ids must be a list of 1-#{MAX_ATTACHMENTS} upload ids", { parameter: "attachment_ids" })
          end
          attachment_ids = Array(attachment_ids)
          content = "" if content.nil? && attachment_ids.any?
          unless content.is_a?(String) && (content.present? || attachment_ids.any?)
            return render_error(:unprocessable_entity, "invalid_parameter", "content is required", { parameter: "content" })
          end

          # A retry resolves its files only to compare them, never to attach.
          blobs = attachment_ids.map { |id| ActiveStorage::Blob.find_signed(id) }
          existing = find_submission(client_message_id)
          return render_retry(existing, content, blobs) if existing

          unless @chat.respondable?
            return render_error(:unprocessable_entity, "conversation_not_respondable", "This conversation is archived and cannot receive new messages")
          end
          if (refusal = attachment_refusal(blobs))
            # A same-key twin that committed since the lookup above has taken
            # these uploads; that is this send's retry, not a refusal.
            if refusal[1] == "invalid_attachment" && (twin = find_submission(client_message_id))
              return render_retry(twin, content, blobs)
            end

            return render_error(*refusal)
          end

          result = begin
            Messages::PostFromHuman.new(chat: @chat, user: current_user, content: content, files: blobs.presence, client_message_id: client_message_id)
              .call(on_persisted: ->(message) { audit("create_message", message, content: content, client_message_id: client_message_id, attachments: blobs.map(&:filename).map(&:to_s)) })
          rescue ActiveRecord::RecordNotUnique
            raise
          rescue StandardError => e
            # Acceptance is one transaction, so nothing of this send exists.
            # Failures after its commit never reach here (PostFromHuman).
            Rails.logger.error "[Api::App::V1::Messages] send failed: #{e.class}: #{e.message}"
            return render_error(:service_unavailable, "send_failed", "The message could not be sent; nothing was saved", { retryable: true })
          end

          if result.created?
            render json: sent(result.message), status: :created
          elsif result.dispatch_unavailable?
            render_error :service_unavailable, "dispatch_unavailable",
                         "Residents cannot be woken right now; the message was not sent", { retryable: true }
          elsif result.attachment_claimed?
            # Another send took an upload between the check above and this
            # one's acceptance. If it was this same send, that is its retry.
            if (twin = find_submission(client_message_id))
              return render_retry(twin, content, blobs)
            end

            render_error :unprocessable_entity, "invalid_attachment", "An attachment is not an upload for this conversation"
          elsif result.duplicate?
            # A concurrent twin that commits before this save is validated trips
            # the web's repeat guard (same content as the last message) before
            # the unique index can; it is still a retry, not a refusal.
            if (twin = find_submission(client_message_id))
              return render_retry(twin, content, blobs)
            end

            render_error :unprocessable_entity, "duplicate_message", "This is the same as the conversation's last message"
          else
            render_error :unprocessable_entity, "invalid_message", result.message.errors.full_messages.to_sentence
          end
        rescue ActiveRecord::RecordNotUnique
          # A concurrent request with the same identity committed first; its
          # transaction woke the residents, this one rolled back entirely.
          existing = find_submission(client_message_id) or raise
          render_retry(existing, content, blobs)
        end

        def update
          content = params[:content]
          unless content.is_a?(String) && content.present?
            return render_error(:unprocessable_entity, "invalid_parameter", "content is required", { parameter: "content" })
          end

          old_content = @message.content
          if @message.update_as_author(content: content)
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
            @message.discard_as_author!
          end
          render json: { message: Presenter.message(@message, viewer: current_user) }
        end

        # Where the wake a send asked for stands (#94 B, step 4b-ii). Dispatch
        # changes take no message revision, so this is how the author observes
        # pending becoming reserved, cancelled or expired. null when the send
        # mentioned no one.
        def dispatch_status
          render json: { dispatch: @message.message_dispatch&.as_app_json }
        end

        private

        def set_conversation
          @chat = find_conversation!(params[:conversation_id])
        end

        # Only delete (a repeat is a no-op) and dispatch status may find an
        # already-discarded message; an edit of a discarded message is 404.
        def set_message
          scope = action_name.in?(%w[destroy dispatch_status]) ? @chat.messages : @chat.messages.kept
          @message = scope.find(params[:id])
        end

        # The author's own human messages only. Unlike the web there is no
        # site-admin override, as for reads (ADR 0003).
        def authorize_message_modification
          return if @message.role == "user" && @message.user_id == current_user.id

          render_error :forbidden, "forbidden", "Only the author can change this message"
        end

        def sent(message)
          { message: Presenter.message(message, viewer: current_user), dispatch: message.message_dispatch&.as_app_json }
        end

        def find_submission(client_message_id)
          @chat.messages.find_by(user: current_user, client_message_id: client_message_id)
        end

        # Authority for a file is the upload's: made by this user for this
        # conversation (uploads#create) and not yet part of any message. A
        # signed id alone is not enough, since one can outlive its purpose.
        # Returns render_error arguments when a file can't be sent, else nil.
        def attachment_refusal(blobs)
          blobs.each_with_index do |blob, index|
            upload = blob&.metadata&.dig("app_upload") || {}
            unless blob && upload["user_id"] == current_user.id && upload["chat_id"] == @chat.id && !blob.attachments.exists?
              return [ :unprocessable_entity, "invalid_attachment", "An attachment is not an upload for this conversation", { index: index } ]
            end
            unless blob.service.exist?(blob.key)
              return [ :unprocessable_entity, "upload_incomplete", "An attachment has not finished uploading; nothing was saved", { index: index, retryable: true } ]
            end
          end
          nil
        end

        def render_retry(message, content, blobs)
          if message.submission_digest == Messages::PostFromHuman.submission_digest(content: content, blobs: blobs)
            # A retry never creates or re-drives anything: 200 means accepted,
            # nothing more. It settles what already lapsed so the status it
            # returns is current; a lost wake is asked for again explicitly.
            begin
              message.message_dispatch&.settle_lapsed!
            rescue StandardError => e
              Rails.logger.warn "[Api::App::V1::Messages] retry settle of message #{message.id} failed: #{e.class}: #{e.message}"
            end
            render json: sent(message), status: :ok
          else
            render_error :conflict, "idempotency_conflict", "client_message_id was already used for a different message",
                         { message_id: message.to_param }
          end
        end

      end
    end
  end
end
