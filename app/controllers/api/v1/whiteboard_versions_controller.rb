module Api
  module V1
    # Past states of a whiteboard (a Field note): GET .../whiteboards/:id/versions
    # lists them newest first, GET .../versions/:version_id reads one in full.
    class WhiteboardVersionsController < BaseController

      include ApiHomeAccountOnly

      def index
        render json: {
          whiteboard: { id: whiteboard.to_param, name: whiteboard.name, revision: whiteboard.revision }
        }.merge(NoteVersions.page_json(whiteboard, before: params[:before]))
      end

      def show
        version = whiteboard.past_versions.find(params[:id])
        render json: { version: NoteVersions.full_json(version) }
      end

      private

      def whiteboard
        @whiteboard ||= current_api_account.whiteboards.active.find(params[:whiteboard_id])
      end

    end
  end
end
