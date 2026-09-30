module Api
  module App
    module V1
      # Ordered reconciliation (ADR 0004). Every message whose revision is past
      # the client's cursor, in revision order: current state for kept messages,
      # a marker for discarded ones. Revisions are allocated under the chat row
      # lock inside the writing transaction, so they commit in order and a row
      # can never commit behind a cursor that has already passed it. since is
      # required: bootstrap is an explicit since=0, and a missing cursor is a
      # 422 rather than a silent re-sync from the start.
      class ChangesController < BaseController

        # messages.revision is a signed bigint; a larger cursor would overflow
        # the query instead of failing validation.
        MAX_REVISION = 2**63 - 1
        DEFAULT_LIMIT = 100
        MAX_LIMIT = 500

        def index
          chat = find_conversation!(params[:conversation_id])
          since = bounded_integer(:since, default: :required, min: 0, max: MAX_REVISION) or return
          limit = bounded_integer(:limit, default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT) or return

          # Read the head before the page: anything committed after this read
          # has a higher revision, so has_more stays conservative, never false early.
          latest_revision = chat.reload.message_revision
          rows = Message.with_discarded.where(chat_id: chat.id).where("revision > ?", since)
            .includes(:chat, :user, :agent).with_attached_attachments
            .reorder(:revision).limit(limit + 1).to_a
          has_more = rows.size > limit
          rows = rows.first(limit)

          render json: {
            changes: rows.map { |m| Presenter.message(m, viewer: current_user) },
            next_since: rows.last&.revision || since,
            has_more: has_more,
            latest_revision: [ latest_revision, rows.last&.revision || 0 ].max
          }
        end

      end
    end
  end
end
