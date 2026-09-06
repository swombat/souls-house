class AddMnemodyneOperations < ActiveRecord::Migration[8.1]

  def change
    add_column :mnemodyne_vaults, :suspended_at, :datetime
    create_table :mnemodyne_operations, id: :uuid do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: { to_table: :mnemodyne_vaults }
      t.string :key, null: false
      t.string :request_digest, null: false
      t.jsonb :result, null: false
      t.timestamps
    end
    add_index :mnemodyne_operations, [ :vault_id, :key ], unique: true
  end

end
