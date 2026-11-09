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
  # tag doesn't jump rooms, and keeps the sidebar's Filter (Archived, Hidden,
  # one tag), so the conversation being edited doesn't drop out of the list.
  # The originating view is read from this request (its params or the page
  # that sent it), never from the session, which another tab may have
  # changed. A bare link still opens the chat's own room.
  def chat_view_path(chat)
    account_chat_path(current_account, chat, **originating_view_params)
  end

  # Only these sidebar parameters, only in these shapes, travel through a
  # redirect. A key in this request wins over the page that sent it; a
  # request param in another shape (a room ID when moving a conversation)
  # leaves the sending page's value alone.
  def originating_view_params
    keep = lambda do |source|
      kept = {}
      kept[:room] = ALL if source["room"] == ALL
      kept[:show_archived] = true if source["show_archived"] == "true"
      kept[:show_hidden] = true if source["show_hidden"] == "true"
      kept[:tag] = source["tag"] if source["tag"].is_a?(String) && source["tag"].match?(/\A[a-zA-Z]{1,32}\z/)
      kept
    end
    keep.call(referer_query).merge(keep.call(params.to_unsafe_h.slice("room", "show_archived", "show_hidden", "tag")))
  end

  def referer_query
    query = URI.parse(request.referer.to_s).query
    query.present? ? Rack::Utils.parse_query(query) : {}
  rescue URI::InvalidURIError
    {}
  end

end
