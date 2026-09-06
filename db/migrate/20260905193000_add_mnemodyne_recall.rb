class AddMnemodyneRecall < ActiveRecord::Migration[8.1]

  def change
    add_column :mnemodyne_nodes, :embedding, :float, array: true
    add_column :mnemodyne_nodes, :embedding_digest, :string
    add_column :mnemodyne_vaults, :last_decay_on, :date
    add_column :mnemodyne_vaults, :decay_rate, :float, null: false, default: 0.005
    add_check_constraint :mnemodyne_vaults, "decay_rate >= 0 AND decay_rate <= 1", name: "mnemodyne_decay_range"
    create_table :mnemodyne_uses, id: :uuid do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: { to_table: :mnemodyne_vaults }
      t.uuid :recall_id, null: false
      t.uuid :node_id, null: false
      t.float :delta, null: false
      t.string :reason, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :mnemodyne_uses, [ :vault_id, :recall_id, :node_id ], unique: true
    add_foreign_key :mnemodyne_uses, :mnemodyne_nodes,
      column: [ :vault_id, :node_id ], primary_key: [ :vault_id, :id ], on_delete: :cascade
  end

end
