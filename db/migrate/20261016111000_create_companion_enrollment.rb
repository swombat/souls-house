class CreateCompanionEnrollment < ActiveRecord::Migration[8.1]

  def change
    create_table :companion_enrollment_grants do |t|
      t.references :account, null: false, foreign_key: true
      t.references :minting_agent, null: false, foreign_key: { to_table: :agents }
      t.references :created_by_user, null: false, foreign_key: { to_table: :users }
      t.string :device_request_id, null: false, limit: 128
      t.string :name, null: false, limit: 100
      t.jsonb :policy, null: false
      t.datetime :expires_at, null: false
      t.string :token_digest, limit: 64
      t.datetime :consumed_at
      t.datetime :enrollment_retry_until
      t.text :enrollment_response
      t.timestamps
    end
    add_index :companion_enrollment_grants, :token_digest, unique: true

    create_table :companion_devices do |t|
      t.references :account, null: false, foreign_key: true
      t.references :companion_enrollment_grant, null: false, foreign_key: true, index: { unique: true }
      t.string :name, null: false, limit: 100
      t.jsonb :policy, null: false
      t.integer :grant_revision, null: false, default: 1
      t.string :credential_digest, null: false, limit: 64
      t.string :previous_credential_digest, limit: 64
      t.string :session_request_id, limit: 128
      t.datetime :session_retry_until
      # Rails encrypted attribute; never a plaintext credential/ticket cache.
      t.text :session_response
      t.boolean :paused, null: false, default: false
      t.string :connection_epoch
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :companion_devices, :credential_digest, unique: true
    add_index :companion_devices, :previous_credential_digest, unique: true
    add_check_constraint :companion_devices, "grant_revision > 0", name: "companion_device_positive_revision"

    create_table :companion_cable_tickets do |t|
      t.references :companion_device, null: false, foreign_key: true
      t.string :token_digest, null: false, limit: 64
      t.integer :grant_revision, null: false
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps
    end
    add_index :companion_cable_tickets, :token_digest, unique: true
  end

end
