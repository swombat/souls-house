class AddHidesFromListToVisualTags < ActiveRecord::Migration[8.1]

  # A tag can hide its conversations from the sidebar (JOyDXe): they are not
  # archived, they just stay out of the list until the tag comes off, or the
  # Filter menu shows hidden ones or that tag.
  def change
    add_column :visual_tags, :hides_from_list, :boolean, default: false, null: false
  end

end
