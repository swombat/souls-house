module Api
  module V1
    class WhiteboardsController < BaseController

      rescue_from ActiveRecord::StaleObjectError do
        render json: { error: "Whiteboard was modified by another user" }, status: :conflict
      end

      def index
        whiteboards = current_api_account.whiteboards.active.by_name
        render json: { whiteboards: whiteboards.map { |w| whiteboard_summary(w) } }
      end

      def create
        whiteboard = current_api_account.whiteboards.create!(
          name: params[:name],
          content: params[:content],
          summary: params[:summary],
          last_edited_by: current_api_user
        )

        render json: {
          whiteboard: {
            id: whiteboard.to_param,
            name: whiteboard.name,
            lock_version: whiteboard.lock_version
          }
        }, status: :created
      rescue ActiveRecord::RecordInvalid => e
        render json: { error: e.record.errors.full_messages.to_sentence }, status: :unprocessable_entity
      end

      def show
        whiteboard = current_api_account.whiteboards.active.find(params[:id])
        render json: {
          whiteboard: {
            id: whiteboard.to_param,
            name: whiteboard.name,
            content: whiteboard.content,
            summary: whiteboard.summary,
            lock_version: whiteboard.lock_version,
            last_edited_at: whiteboard.last_edited_at&.iso8601,
            editor_name: whiteboard.editor_name
          }
        }
      end

      def update
        whiteboard = current_api_account.whiteboards.active.find(params[:id])
        attributes = params.permit(:name, :summary, :content)
        lock_version = Integer(params[:lock_version], exception: false)

        return render_update_error("lock_version must be an integer") if lock_version.nil?
        return render_update_error("Provide name, summary, or content") if attributes.empty?
        return render_update_error("Provided name, summary, and content must not be null") if attributes.values.any?(&:nil?)

        whiteboard.lock_version = lock_version
        whiteboard.update!(attributes.merge(last_edited_by: current_api_user))

        render json: { whiteboard: { id: whiteboard.to_param, lock_version: whiteboard.lock_version } }
      rescue ActiveRecord::RecordInvalid => e
        render_update_error(e.record.errors.full_messages.to_sentence)
      end

      private

      def render_update_error(error)
        render json: { error: error }, status: :unprocessable_entity
      end

      def whiteboard_summary(whiteboard)
        {
          id: whiteboard.to_param,
          name: whiteboard.name,
          summary: whiteboard.summary,
          content_length: whiteboard.content.to_s.length,
          lock_version: whiteboard.lock_version
        }
      end

    end
  end
end
