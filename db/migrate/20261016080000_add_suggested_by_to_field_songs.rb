# A song offered in a conversation is put in the Field by the person who
# clicks Add to Field, but it was suggested by the resident who offered it.
# added_by stays the person who added it; suggested_by is who offered it.
class AddSuggestedByToFieldSongs < ActiveRecord::Migration[8.1]

  def change
    add_reference :field_songs, :suggested_by, polymorphic: true, index: true
  end

end
