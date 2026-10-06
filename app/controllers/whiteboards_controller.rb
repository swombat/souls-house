class WhiteboardsController < ApplicationController

  # Whiteboards are shown as "notes" inside the Field. The model and the
  # resident API keep the whiteboard name so existing scripts keep working.
  require_feature_enabled :agents
  before_action :set_whiteboard, only: [ :update, :destroy ]

  def index
    note = current_account.whiteboards.active.find_by(id: Whiteboard.decode_id(params[:id])) if params[:id].present?
    item = note ? "note-#{note.to_param}" : nil
    redirect_to account_field_path(current_account, tab: "notes", item: item)
  end

  def create
    whiteboard = current_account.whiteboards.new(
      name: params.dig(:whiteboard, :name),
      content: params.dig(:whiteboard, :content).to_s,
      last_edited_by: Current.user
    )

    if whiteboard.save
      redirect_to account_field_path(current_account, tab: "notes", item: "note-#{whiteboard.to_param}")
    else
      redirect_to account_field_path(current_account, tab: "notes"), alert: whiteboard.errors.full_messages.to_sentence
    end
  end

  def update
    if params[:expected_revision].present? && @whiteboard.revision != params[:expected_revision].to_i
      render json: {
        error: "conflict",
        current_content: @whiteboard.content,
        current_revision: @whiteboard.revision
      }, status: :conflict
      return
    end

    if @whiteboard.update(whiteboard_params.merge(last_edited_by: Current.user))
      head :ok
    else
      render json: { errors: @whiteboard.errors.full_messages }, status: :unprocessable_entity
    end
  end

  def destroy
    @whiteboard.soft_delete!
    redirect_to account_field_path(current_account, tab: "notes"), notice: "Note deleted."
  end

  private

  def set_whiteboard
    @whiteboard = current_account.whiteboards.active.find(params[:id])
  end

  def whiteboard_params
    params.require(:whiteboard).permit(:content)
  end

end
