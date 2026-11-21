# How many conversations each of an account's rooms holds, for the faint
# totals in the room menus when the account has show_room_chat_counts on.
# The same conversations a room's list shows by default: not deleted, not
# archived, not quiet rhythm runs, not hidden by their tag. Every member of an
# account sees the same list, except private conversations they aren't in
# (eKmnrJ), so the totals are counted for the viewer.
# One grouped query for every room.
#
#   { rooms: { "main" => 4, "<room id>" => 12, ... }, all: 16 }
#
# nil when the switch is off, so nothing is sent or shown.
class RoomChatCounts

  def self.summary_for(account, viewer: nil)
    return nil unless account&.show_room_chat_counts?

    by_room = account.chats.visible_to_or_unprivate(viewer).kept.listed.active.not_hidden_from_list.group("chats.room_id").count
    rooms = by_room.each_with_object({}) do |(room_id, count), counts|
      counts[room_id ? Room.encode_id(room_id) : "main"] = count
    end
    { rooms: rooms, all: by_room.values.sum }
  end

end
