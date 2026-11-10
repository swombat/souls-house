class CreateStoneRevisionFieldTables < ActiveRecord::Migration[8.1]

  # Field tables an interactive stone revision reads. Attaching publishes the
  # table's rows to anyone with the stone's link; the viewer fetches them from
  # an endpoint bound to this exact revision and hands them to the frame.
  def change
    create_table :stone_revision_field_tables do |t|
      t.references :stone_revision, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :field_table, null: false, foreign_key: { on_delete: :cascade }
      t.references :attached_by, polymorphic: true
      t.timestamps
    end
    add_index :stone_revision_field_tables, %i[stone_revision_id field_table_id], unique: true,
      name: "index_stone_revision_field_tables_unique"
  end

end
