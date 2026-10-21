class Accounts::RoomsController < ApplicationController

  before_action :require_account_manager!, except: :index

  def index
    counts = current_account.chats.kept.group(:room_id).count
    render inertia: "accounts/rooms", props: {
      account: current_account.as_json,
      can_manage: current_account.manageable_by?(Current.user),
      main_count: counts.fetch(nil, 0),
      rooms: -> { current_account.rooms.map(&:directory_json) },
      room_counts: counts.except(nil).transform_keys { |id| Room.encode_id(id) },
      resident_room_id: current_account.resident_room&.to_param,
      model_residents: -> { model_residents },
      room_model_defaults: -> { current_account.room_model_defaults.includes(:room, :agent).map(&:as_json) }
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

  # Residents of this account that can run on more than one model in a
  # conversation: the ones a room can start on something else. A resident with
  # a stored room default stays listed after losing its alternatives, so the
  # stale default is shown and can be cleared rather than silently returning
  # if the model is listed again.
  def model_residents
    with_defaults = current_account.room_model_defaults.distinct.pluck(:agent_id)
    current_account.agents.by_name.select do |agent|
      (agent.active? && agent.model_switching_available?) || with_defaults.include?(agent.id)
    end.map do |agent|
      { id: agent.to_param, name: agent.name, colour: agent.colour, default_label: agent.model_label,
        choices: agent.model_choices }
    end
  end

  def room_params
    params.require(:room).permit(:name, :description)
  end

  def redirect_validation_errors(room)
    redirect_to account_rooms_path(current_account), inertia: { errors: room.errors.to_hash }
  end

end
