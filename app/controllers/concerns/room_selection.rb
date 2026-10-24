# Which room the chat list is showing, per session and account. One state is
# shared by the navbar's Chat menu and the sidebar switcher.
#   nil   -> Main (conversations with no room)
#   :all  -> every room (a view, not a place)
#   Room  -> that room
module RoomSelection

  extend ActiveSupport::Concern

  ALL = "all".freeze
  MAIN = "main".freeze

  private

  def selected_room
    return @selected_room if defined?(@selected_room)

    @selected_room = room_from_key(session.dig(:rooms, current_account.id.to_s))
  end

  def select_room!(selection)
    @selected_room = selection
    session[:rooms] = (session[:rooms] || {}).merge(current_account.id.to_s => room_key(selection))
  end

  # An unknown or deleted room quietly falls back to Main.
  def room_from_key(key)
    case key
    when nil, MAIN then nil
    when ALL then :all
    else Room.resolve_for(current_account, key)
    end
  rescue ActiveRecord::RecordNotFound
    nil
  end

  def room_key(selection)
    case selection
    when nil then MAIN
    when :all then ALL
    else selection.to_param
    end
  end

  def selected_room_key
    room_key(selected_room)
  end

  # Where an in-place action on a conversation returns. Keeps All chats when
  # the page the action came from was in All chats, so editing a title or a
  # tag doesn't jump rooms. The originating view is read from this request
  # (its room param or the page that sent it), never from the session, which
  # another tab may have changed. A bare link still opens the chat's own room.
  def chat_view_path(chat)
    from_all_chats? ? account_chat_path(current_account, chat, room: ALL) : account_chat_path(current_account, chat)
  end

  def from_all_chats?
    return true if params[:room] == ALL

    query = URI.parse(request.referer.to_s).query
    query.present? && Rack::Utils.parse_query(query)["room"] == ALL
  rescue URI::InvalidURIError
    false
  end

end
