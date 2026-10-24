# Where a rhythm's conversations open. Three explicit choices rather than one
# nullable column doing two jobs: follow the account's resident default room
# (the default, so a house that sets its room once gets it), Main on purpose,
# or a named room. A named room that is removed leaves room_id null and the
# rhythm falls back to the account default, saying so on its page.
class AddRoomChoiceToRhythms < ActiveRecord::Migration[8.1]

  def change
    add_column :rhythms, :room_choice, :string, null: false, default: "resident_default"
    add_reference :rhythms, :room, foreign_key: { on_delete: :nullify }, index: true
    add_check_constraint :rhythms, "room_choice IN ('resident_default', 'main', 'room')",
      name: "rhythms_room_choice_known"
  end

end
