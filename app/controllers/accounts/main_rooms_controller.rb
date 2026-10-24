# Main has no row: its name and description are account settings.
class Accounts::MainRoomsController < ApplicationController

  before_action :require_account_manager!

  def update
    current_account.update!(main_room_params)
    audit_with_changes(:update_main_room, current_account)
    ActionCable.server.broadcast("RoomNavigation:#{current_account.to_param}", { action: "refresh" })
    redirect_to account_rooms_path(current_account)
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_rooms_path(current_account), inertia: { errors: error.record.errors.to_hash }
  end

  private

  def main_room_params
    params.require(:main_room).permit(:name, :description).to_h.transform_keys { |key| "main_room_#{key}" }
  end

end
