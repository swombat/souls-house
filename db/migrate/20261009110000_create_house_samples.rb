class CreateHouseSamples < ActiveRecord::Migration[8.0]

  def change
    create_table :house_samples do |t|
      # host · hetzner_vm · resident_disk · restic_storage · pricing
      t.string :kind, null: false
      # "house", "hetzner:<server id>", or empty for per-resident kinds
      t.string :subject, null: false, default: ""
      t.references :agent, foreign_key: { on_delete: :cascade }, null: true
      t.datetime :sampled_at, null: false
      t.jsonb :metrics, null: false, default: {}
      t.timestamps
    end
    add_index :house_samples, %i[kind sampled_at]
    add_index :house_samples, %i[kind subject sampled_at]
    add_index :house_samples, %i[agent_id kind sampled_at]
  end

end
