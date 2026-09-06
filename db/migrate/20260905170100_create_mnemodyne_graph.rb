class CreateMnemodyneGraph < ActiveRecord::Migration[8.1]

  def change
    create_table :mnemodyne_vaults, id: :uuid do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.boolean :auto_preview_enabled, null: false, default: false
      t.timestamps
    end

    create_table :mnemodyne_nodes, id: :uuid do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: { to_table: :mnemodyne_vaults }
      t.string :node_type, null: false
      t.text :content, null: false
      t.text :description
      t.float :charge, null: false, default: 0.5
      t.string :integration_state, null: false, default: "raw"
      t.boolean :is_dormant, null: false, default: false
      t.text :source_uris, array: true, null: false, default: []
      t.jsonb :metadata, null: false, default: {}
      t.string :disclosure, null: false, default: "never_automatic"
      t.string :embedding_profile
      t.timestamps
    end

    add_index :mnemodyne_nodes, [ :vault_id, :id ], unique: true
    add_index :mnemodyne_nodes, [ :vault_id, :node_type ]
    add_index :mnemodyne_nodes, "vault_id, node_type, lower(content)",
      unique: true, where: "node_type IN ('need', 'person')", name: "index_mnemodyne_hubs_unique_per_vault"
    add_check_constraint :mnemodyne_nodes, "charge >= 0 AND charge <= 1", name: "mnemodyne_node_charge_range"
    add_check_constraint :mnemodyne_nodes, "integration_state IN ('raw', 'active', 'integrated', 'constitutional')",
      name: "mnemodyne_node_integration_state"
    add_check_constraint :mnemodyne_nodes, "disclosure IN ('automatic', 'never_automatic')",
      name: "mnemodyne_node_disclosure"
    add_check_constraint :mnemodyne_nodes, "jsonb_typeof(metadata) = 'object'", name: "mnemodyne_node_metadata_object"

    create_table :mnemodyne_edges, id: :uuid do |t|
      t.references :vault, type: :uuid, null: false, foreign_key: { to_table: :mnemodyne_vaults }
      t.uuid :source_id, null: false
      t.uuid :target_id, null: false
      t.string :edge_type, null: false
      t.float :weight, null: false, default: 0.5
      t.jsonb :metadata, null: false, default: {}
      t.timestamps
    end

    add_index :mnemodyne_edges, [ :vault_id, :source_id, :target_id, :edge_type ],
      unique: true, name: "index_mnemodyne_edges_unique_per_vault"
    add_index :mnemodyne_edges, [ :vault_id, :target_id ]
    add_foreign_key :mnemodyne_edges, :mnemodyne_nodes,
      column: [ :vault_id, :source_id ], primary_key: [ :vault_id, :id ], on_delete: :cascade
    add_foreign_key :mnemodyne_edges, :mnemodyne_nodes,
      column: [ :vault_id, :target_id ], primary_key: [ :vault_id, :id ], on_delete: :cascade
    add_check_constraint :mnemodyne_edges, "source_id <> target_id", name: "mnemodyne_edge_no_self_loop"
    add_check_constraint :mnemodyne_edges, "weight >= 0 AND weight <= 1", name: "mnemodyne_edge_weight_range"
    add_check_constraint :mnemodyne_edges, "jsonb_typeof(metadata) = 'object'", name: "mnemodyne_edge_metadata_object"
  end

end
