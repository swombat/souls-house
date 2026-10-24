# The model a resident starts on in new conversations in a room (Main is
# room_id "main"). Choosing the resident's own default clears the room's.
class Accounts::RoomModelDefaultsController < ApplicationController

  before_action :require_account_manager!

  def update
    room = params[:room_id] == "main" ? nil : Room.resolve_for(current_account, params[:room_id])
    agent = current_account.agents.find(Agent.decode_id(params[:agent_id].to_s) || 0)
    record = RoomModelDefault.set!(account: current_account, room: room, agent: agent, model_id: params[:model_id])
    audit(:update_room_model_default, room || current_account,
      room: room&.name || current_account.main_room_label, agent: agent.name, model_id: record&.model_id)
    redirect_to account_rooms_path(current_account), notice: "#{agent.name} in #{room&.name || current_account.main_room_label}: " \
      "#{record ? Agent.label_for_model(record.model_id) : "their own default (#{agent.model_label})"} for new conversations"
  rescue ActiveRecord::RecordInvalid => error
    redirect_to account_rooms_path(current_account), inertia: { errors: { room_model: error.record.errors.full_messages.to_sentence } }
  end

end
