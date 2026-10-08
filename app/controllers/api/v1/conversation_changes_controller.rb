module Api
  module V1
    # Ordered reconciliation (ADR 0004) for a person's credential: every message
    # whose revision is past the client's cursor, in revision order. Same
    # contract and presenter as /api/app/v1/conversations/:id/changes.
    class ConversationChangesController < BaseController

      MAX_REVISION = 2**63 - 1
      DEFAULT_LIMIT = 100
      MAX_LIMIT = 500

      before_action :require_human_actor!

      def index
        chat = human_chats.kept.find(params[:conversation_id])
        human_account!(chat.account)
        since = bounded_param(:since, required: true, min: 0, max: MAX_REVISION) or return
        limit = bounded_param(:limit, default: DEFAULT_LIMIT, min: 1, max: MAX_LIMIT) or return

        latest_revision = chat.reload.message_revision
        rows = Message.with_discarded.where(chat_id: chat.id).where("revision > ?", since)
          .includes(:chat, :user, :agent).with_attached_attachments
          .reorder(:revision).limit(limit + 1).to_a
        has_more = rows.size > limit
        rows = rows.first(limit)

        render json: {
          changes: rows.map { |m| Api::App::V1::Presenter.message(m, viewer: current_api_user) },
          next_since: rows.last&.revision || since,
          has_more: has_more,
          latest_revision: [ latest_revision, rows.last&.revision || 0 ].max
        }
      end

      def activity
        chat = human_chats.kept.find(params[:conversation_id])
        human_account!(chat.account)
        render json: { activity: chat.activity_timeline.map { |interaction| Api::App::V1::Presenter.activity(interaction) } }
      end

      private

      def bounded_param(name, min:, max:, default: nil, required: false)
        raw = params[name]
        if raw.blank?
          return default unless required

          render json: { error: "#{name} is required" }, status: :unprocessable_entity
          return
        end
        value = Integer(raw.to_s, 10, exception: false)
        return value if value && value >= min && value <= max

        render json: { error: "#{name} must be an integer #{min}..#{max}" }, status: :unprocessable_entity
        nil
      end

    end
  end
end
