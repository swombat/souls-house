module Api
  module V1
    class WhiteboardsController < BaseController

      include ApiHumanReach
      include ApiHomeAccountOnly

      # Deleting a note is the person's control in the Field
      # (WhiteboardsController#destroy), in the note's own account. Residents
      # edit, but don't delete.
      before_action :require_human_actor!, only: :destroy
      require_api_feature_enabled :agents, only: :destroy

      rescue_from ActiveRecord::StaleObjectError do
        render json: { error: "Whiteboard was modified by another user" }, status: :conflict
      end

      rescue_from FieldDate::Invalid do |e|
        render json: { error: e.message }, status: :unprocessable_entity
      end

      def index
        whiteboards = current_api_account.whiteboards.active.by_name
        render json: { whiteboards: whiteboards.map { |w| whiteboard_summary(w) } }
      end

      # dated_at (ISO 8601) is when the note is from, for an import of old
      # notes or transcripts; the Field orders by it instead of the last edit.
      def create
        whiteboard = current_api_account.whiteboards.create!(
          name: params[:name],
          content: params[:content],
          summary: params[:summary],
          dated_at: (FieldDate.parse(params[:dated_at], param: "dated_at") if params[:dated_at].present?),
          last_edited_by: current_api_editor
        )

        render json: {
          whiteboard: {
            id: whiteboard.to_param,
            name: whiteboard.name,
            dated_at: whiteboard.dated_at&.iso8601,
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
            dated_at: whiteboard.dated_at&.iso8601,
            last_edited_at: whiteboard.last_edited_at&.iso8601,
            editor_name: whiteboard.editor_name
          }
        }
      end

      # dated_at may be sent alone; empty clears it.
      def update
        whiteboard = current_api_account.whiteboards.active.find(params[:id])
        attributes = params.permit(:name, :summary, :content)
        lock_version = Integer(params[:lock_version], exception: false)

        return render_update_error("lock_version must be an integer") if lock_version.nil?
        return render_update_error("Provided name, summary, and content must not be null") if attributes.values.any?(&:nil?)

        attributes[:dated_at] = FieldDate.parse_or_clear(params[:dated_at], param: "dated_at") if params.key?(:dated_at)
        return render_update_error("Provide name, summary, content, or dated_at") if attributes.empty?

        whiteboard.lock_version = lock_version
        # Redating alone isn't an edit of what the note says.
        attributes = attributes.merge(last_edited_by: current_api_editor) unless attributes.except(:dated_at).empty?
        whiteboard.update!(attributes)

        render json: { whiteboard: { id: whiteboard.to_param, dated_at: whiteboard.dated_at&.iso8601,
                                     lock_version: whiteboard.lock_version } }
      rescue ActiveRecord::RecordInvalid => e
        render_update_error(e.record.errors.full_messages.to_sentence)
      end

      # A soft delete, as on the page: the note leaves the Field.
      def destroy
        find_human_record!(Whiteboard.active, params[:id]).soft_delete!
        head :no_content
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
          dated_at: whiteboard.dated_at&.iso8601,
          lock_version: whiteboard.lock_version
        }
      end

    end
  end
end
