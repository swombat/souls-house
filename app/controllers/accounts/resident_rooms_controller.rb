# Where conversations residents start land when they don't choose a room.
class Accounts::ResidentRoomsController < ApplicationController

  before_action :require_account_manager!

  def update
    current_account.update!(resident_room: Room.resolve_for(current_account, params[:room_id].presence))
    audit_with_changes(:update_resident_room, current_account)
    redirect_to account_rooms_path(current_account), notice: "Default room for residents updated"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_rooms_path(current_account), inertia: { errors: { base: error.record.errors.full_messages.to_sentence } }
  end

end
