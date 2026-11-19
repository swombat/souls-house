# The conversation list's Filter, shared by the list itself (ChatsController)
# and the Actions menu that acts on everything it shows
# (Chats::BulkActionsController), so the two can never disagree about which
# conversations "this list" means.
module ChatSidebarScope

  extend ActiveSupport::Concern

  private

  # Every kept conversation the list shows in this room with this filter,
  # unordered: the relation the Actions menu acts on. Deleted conversations
  # (the admin's show_deleted) are never in it.
  def sidebar_listing(room)
    chats = filter_sidebar_by_tag(current_account.chats.in_room(room).kept).listed
    params[:show_archived] == "true" ? chats : chats.active
  end

  # The Filter menu: a chosen tag shows only its conversations (hidden ones
  # too, since that is what was asked for); otherwise conversations whose tag
  # hides them stay out unless show_hidden is on. An unknown or removed tag
  # filters nothing rather than failing the page.
  def filter_sidebar_by_tag(chats)
    if (tag = sidebar_tag_filter)
      chats.where(visual_tag: tag)
    elsif params[:show_hidden] == "true"
      chats
    else
      chats.not_hidden_from_list
    end
  end

  def sidebar_tag_filter
    return @sidebar_tag_filter if defined?(@sidebar_tag_filter)

    @sidebar_tag_filter = begin
      params[:tag].is_a?(String) ? VisualTag.resolve_for(current_account, params[:tag]) : nil
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end

end
