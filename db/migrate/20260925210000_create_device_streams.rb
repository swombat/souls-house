class CreateDeviceStreams < ActiveRecord::Migration[8.0]

  def down
    drop_table :device_stream_batches
    drop_table :device_stream_sessions
    drop_table :device_stream_credentials
    drop_table :device_streams
  end

  def up
    create_table :device_streams do |t|
      t.references :account, null: false, foreign_key: true
      t.references :subject_user, null: false, foreign_key: { to_table: :users }
      t.string :stream_key, null: false
      t.string :name, null: false
      t.jsonb :reader_user_ids, null: false, default: []
      t.jsonb :reader_agent_ids, null: false, default: []
      t.boolean :enabled, null: false, default: true
      t.integer :batches_count, null: false, default: 0
      t.datetime :erased_at
      t.timestamps
    end
    add_index :device_streams, :stream_key, unique: true

    create_table :device_stream_credentials do |t|
      t.references :device_stream, null: false, foreign_key: true
      t.string :token_digest, null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :device_stream_credentials, :token_digest, unique: true

    create_table :device_stream_sessions do |t|
      t.references :device_stream, null: false, foreign_key: true
      t.string :session_uuid, null: false
      t.datetime :erased_at
      t.timestamps
    end
    add_index :device_stream_sessions, [ :device_stream_id, :session_uuid ], unique: true

    create_table :device_stream_batches do |t|
      t.references :device_stream_session, null: false, foreign_key: true
      t.bigint :sequence, null: false
      t.datetime :observed_at, null: false, precision: 6
      t.jsonb :rr_ms, null: false
      t.string :payload_digest, null: false
      t.timestamps
    end
    add_index :device_stream_batches, [ :device_stream_session_id, :sequence ], unique: true
    add_index :device_stream_batches, :observed_at
    add_index :device_stream_batches, :created_at
    add_check_constraint :device_stream_batches, "sequence >= 0", name: "device_batch_nonnegative_sequence"
  end

end
