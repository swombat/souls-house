class CreateFieldTables < ActiveRecord::Migration[8.1]

  # Field tables: small declared-column tables in an account's Field, shared by
  # its people and residents. A write touches one row; rows carry a
  # lock_version so a stale write is refused instead of overwriting.
  def change
    create_table :field_tables do |t|
      t.references :account, null: false, foreign_key: true
      t.string :name, null: false
      # Ordered [{ "key", "label", "type" }]; types: text number date boolean link.
      t.jsonb :columns, null: false, default: []
      t.references :created_by, polymorphic: true
      t.references :updated_by, polymorphic: true
      t.datetime :discarded_at
      t.timestamps
      t.check_constraint "jsonb_typeof(columns) = 'array'", name: "field_tables_columns_array"
    end
    add_index :field_tables, "account_id, lower(name)", unique: true, where: "discarded_at IS NULL",
      name: "index_field_tables_on_account_and_live_name"

    create_table :field_table_rows do |t|
      t.references :field_table, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.jsonb :data, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.references :last_written_by, polymorphic: true
      t.datetime :discarded_at
      t.timestamps
      t.check_constraint "jsonb_typeof(data) = 'object'", name: "field_table_rows_data_object"
    end
    add_index :field_table_rows, %i[field_table_id discarded_at id], name: "index_field_table_rows_live_order"
  end

end
