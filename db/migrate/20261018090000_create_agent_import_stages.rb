class CreateAgentImportStages < ActiveRecord::Migration[8.1]

  def change
    create_table :agent_import_stages do |t|
      t.references :agent, null: false, foreign_key: true, index: false
      t.string :role, null: false
      t.binary :archive, null: false
      t.string :sha256, null: false
      t.bigint :bytes, null: false
      t.timestamps
    end
    add_index :agent_import_stages, [ :agent_id, :role ], unique: true
    add_check_constraint :agent_import_stages, "role IN ('identity', 'repo', 'work')", name: "agent_import_stages_role"
    add_check_constraint :agent_import_stages, "bytes > 0", name: "agent_import_stages_positive_bytes"
  end

end
