class AddPinsToTopToVisualTags < ActiveRecord::Migration[8.1]

  # Any tag can keep its conversations at the top of the list, not only the
  # built-in Pin (JxGWwj): a conversation carries one tag, so tagging a
  # pinned thread "?" used to unpin it. `pinned` still marks the built-in
  # Pin tag itself, which always keeps its conversations on top.
  def change
    add_column :visual_tags, :pins_to_top, :boolean, default: false, null: false
  end

end
