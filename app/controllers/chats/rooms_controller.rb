# Move one conversation to another room. Main is a null room_id; All chats is
# a view, so it is not a destination.
class Chats::RoomsController < ApplicationController

  def update
    chat = current_account.chats.kept.find(params[:chat_id])
    unless params.key?(:room_id)
      redirect_back_or_to account_chat_path(current_account, chat),
        inertia: { errors: { room_id: "must be provided (or null for Main)" } }
      return
    end

    chat.update!(room: Room.resolve_for(current_account, params[:room_id]))
    redirect_back_or_to account_chat_path(current_account, chat)
  rescue ActiveRecord::InvalidForeignKey
    redirect_back_or_to account_chat_path(current_account, chat),
      inertia: { errors: { room_id: "This room is no longer available. Refresh and try again." } }
  end

end
