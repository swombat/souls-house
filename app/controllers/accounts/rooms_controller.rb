class Accounts::RoomsController < ApplicationController

  before_action :require_account_manager!, except: :index

  def index
    counts = current_account.chats.kept.group(:room_id).count
    render inertia: "accounts/rooms", props: {
      account: current_account.as_json,
      can_manage: current_account.manageable_by?(Current.user),
      main_count: counts.fetch(nil, 0),
      rooms: current_account.rooms.map { |room| room.as_json.merge("conversation_count" => counts.fetch(room.id, 0)) },
      resident_room_id: current_account.resident_room&.to_param
    }
  end

  def create
    room = current_account.rooms.create!(room_params)
    audit(:create_room, room)
    redirect_to account_rooms_path(current_account), notice: "Room added"
  rescue ActiveRecord::RecordInvalid => error
    redirect_validation_errors(error.record)
  end

  def update
    room = Room.resolve_for(current_account, params[:id])
    if params[:direction].in?(%w[up down])
      room.move!(params[:direction] == "up" ? -1 : 1)
    else
      room.update!(room_params)
      audit_with_changes(:update_room, room)
    end
    redirect_to account_rooms_path(current_account)
  rescue ActiveRecord::RecordInvalid => error
    redirect_validation_errors(error.record)
  end

  def destroy
    room = Room.resolve_for(current_account, params[:id])
    moved = room.chats.count
    room.destroy!
    audit(:destroy_room, room)
    redirect_to account_rooms_path(current_account),
      notice: "#{room.name} removed; #{helpers.pluralize(moved, 'conversation')} moved to #{Room::MAIN}"
  end

  private

  def room_params
    params.require(:room).permit(:name)
  end

  def redirect_validation_errors(room)
    redirect_to account_rooms_path(current_account), inertia: { errors: room.errors.to_hash }
  end

end
