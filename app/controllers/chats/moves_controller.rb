# Bulk "Move to room…" from the conversation list.
class Chats::MovesController < ApplicationController

  MAX = 500

  def create
    ids = params[:chat_ids]
    unless ids.is_a?(Array) && ids.size.between?(1, MAX) && ids.all? { |id| id.is_a?(String) }
      redirect_back_or_to account_chats_path(current_account),
        inertia: { errors: { chat_ids: "Select between 1 and #{MAX} conversations" } }
      return
    end

    room = Room.resolve_for(current_account, params[:room_id])
    chats = current_account.chats.kept.where(id: Chat.decode_id(ids)).to_a
    # All or nothing: never report success for a selection we only partly moved.
    if chats.size != ids.uniq.size
      missing = ids.uniq.size - chats.size
      redirect_back_or_to account_chats_path(current_account),
        inertia: { errors: { chat_ids: "#{helpers.pluralize(missing, 'selected conversation')} can't be moved (deleted, or no longer here). Nothing was moved." } }
      return
    end
    Chat.transaction { chats.each { |chat| chat.update!(room: room) } }
    audit("move_chats_to_room", room || current_account, count: chats.size)
    redirect_back_or_to account_chats_path(current_account),
      notice: "Moved #{helpers.pluralize(chats.size, 'conversation')} to #{room&.name || Room::MAIN}"
  rescue ActiveRecord::InvalidForeignKey
    redirect_back_or_to account_chats_path(current_account),
      inertia: { errors: { room_id: "This room is no longer available. Refresh and try again." } }
  end

end
