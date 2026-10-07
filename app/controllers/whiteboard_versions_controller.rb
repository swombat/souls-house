# Past states of a Field note, for the note's History panel. JSON only: the
# Field page fetches these when someone opens the panel.
class WhiteboardVersionsController < ApplicationController

  require_feature_enabled :agents

  def index
    render json: NoteVersions.page_json(whiteboard, before: params[:before])
  end

  def show
    version = whiteboard.past_versions.find(params[:id])
    render json: { version: NoteVersions.full_json(version) }
  end

  private

  def whiteboard
    @whiteboard ||= current_account.whiteboards.active.find(params[:whiteboard_id])
  end

end
