# PaperTrail's versions table. One shared table for every versioned item
# (Field notes first). object and object_changes are jsonb so a past state
# can be read with plain SQL as well as reified. item_id is bigint to match
# our primary keys; the obfuscated id is only ever a presentation of it.
class CreateVersions < ActiveRecord::Migration[8.1]

  def change
    create_table :versions do |t|
      t.string :item_type, null: false
      t.bigint :item_id, null: false
      t.string :event, null: false
      # "User:12" or "Agent:34": who made the change. Both kinds of editor
      # write Field notes, so a bare id would be ambiguous.
      t.string :whodunnit
      t.jsonb :object
      t.jsonb :object_changes
      t.datetime :created_at
    end
    add_index :versions, %i[item_type item_id created_at]
  end

end
