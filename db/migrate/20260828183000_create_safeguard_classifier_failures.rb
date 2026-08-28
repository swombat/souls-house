class CreateSafeguardClassifierFailures < ActiveRecord::Migration[8.1]

  def change
    create_table :safeguard_classifier_failures do |t|
      t.references :agent, null: false, foreign_key: true
      t.string :provider, null: false
      t.string :model, null: false
      t.string :detector_version, null: false
      t.string :error_class, null: false

      t.timestamps
    end

    add_index :safeguard_classifier_failures, [ :agent_id, :created_at ]
  end

end
