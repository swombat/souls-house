class CreateAgentPlacements < ActiveRecord::Migration[8.1]

  def change
    create_table :agent_placements do |t|
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.string :backend, null: false, default: "local"
      t.string :state, null: false, default: "pending"
      t.bigint :provider_server_id
      t.string :runtime_endpoint
      t.integer :generation, null: false, default: 1

      t.timestamps
    end

    add_index :agent_placements, :provider_server_id, unique: true,
      where: "provider_server_id IS NOT NULL"
    add_check_constraint :agent_placements, "generation >= 1", name: "agent_placements_positive_generation"
    add_check_constraint :agent_placements, "provider_server_id > 0", name: "agent_placements_positive_server_id"
  end

end
