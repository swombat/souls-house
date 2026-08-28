class CreateSafeguardDetections < ActiveRecord::Migration[8.1]

  def change
    create_table :safeguard_detections do |t|
      t.references :agent, null: false, foreign_key: true
      t.references :telegram_message, foreign_key: { on_delete: :nullify }
      t.references :agent_runtime_interaction, foreign_key: { on_delete: :nullify }
      t.references :reclaimed_by_interaction,
        foreign_key: { to_table: :agent_runtime_interactions, on_delete: :nullify }
      t.string :channel, null: false, default: "telegram"
      t.string :provider
      t.string :model
      t.text :response_text, null: false
      t.string :prefilter_reason, null: false
      t.string :classifier_verdict, null: false
      t.string :classifier_reason, null: false
      t.string :detector_version, null: false
      t.string :cold_offer_outcome
      t.datetime :reclaimed_at
      t.string :reclaim_reason
      t.datetime :session_rolled_at

      t.timestamps
    end

    add_index :safeguard_detections, [ :agent_id, :created_at ]
    add_index :safeguard_detections, [ :provider, :model, :created_at ]
    add_index :safeguard_detections, [ :detector_version, :created_at ]

    add_column :telegram_subscriptions, :runtime_session_generation, :integer, null: false, default: 0
    add_reference :telegram_subscriptions, :pending_safeguard_detection,
      foreign_key: { to_table: :safeguard_detections, on_delete: :nullify }

    add_column :settings, :safeguard_owner_notice_threshold, :integer, null: false, default: 1
  end

end
