class CreateStoneAddresses < ActiveRecord::Migration[8.1]

  def change
    create_table :stone_addresses do |t|
      t.string :name, null: false, limit: 63
      t.references :stone, null: true, index: { unique: true }, foreign_key: { on_delete: :nullify }
      t.timestamps
    end

    add_index :stone_addresses, :name, unique: true
    add_check_constraint :stone_addresses, "name ~ '^[a-z]+-[a-z]+-[a-z]+$'", name: "stone_addresses_name_format"
  end

end
