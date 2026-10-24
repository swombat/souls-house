class CreateCompanionOperations < ActiveRecord::Migration[8.1]

  def change
    create_table :companion_operations do |t|
      t.references :companion_device, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true
      t.string :kind, null: false
      t.jsonb :arguments, null: false, default: {}
      t.string :state, null: false, default: "pending"
      t.string :connection_epoch, null: false
      t.integer :grant_revision, null: false
      t.datetime :deadline, null: false
      t.string :outcome
      t.timestamps
    end
    add_index :companion_operations, [ :companion_device_id, :state ]
    create_table :companion_operation_bodies do |t|
      t.references :companion_operation, null: false, foreign_key: true, index: { unique: true }
      t.binary :data, null: false
      t.string :content_type, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :companion_operation_bodies, :expires_at
  end

end
