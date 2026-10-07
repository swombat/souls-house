class CreateRunnerEnrollments < ActiveRecord::Migration[8.1]

  def change
    create_table :runner_enrollments do |t|
      t.references :agent_placement, null: false, foreign_key: true
      # Set by procurement (#191). No foreign key until that table exists.
      t.bigint :procurement_operation_id
      t.string :public_id, null: false
      t.string :token_digest, null: false
      t.datetime :expires_at, null: false
      t.bigint :expected_provider_server_id
      t.string :public_key
      t.datetime :enrolled_at
      t.datetime :last_heartbeat_at
      t.jsonb :last_facts, null: false, default: {}
      t.datetime :revoked_at

      t.timestamps
    end

    add_index :runner_enrollments, :public_id, unique: true
    add_index :runner_enrollments, :token_digest, unique: true
    add_index :runner_enrollments, :procurement_operation_id, unique: true,
      where: "procurement_operation_id IS NOT NULL"
    add_check_constraint :runner_enrollments, "expected_provider_server_id > 0",
      name: "runner_enrollments_positive_server_id"

    create_table :runner_request_nonces do |t|
      t.references :runner_enrollment, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :nonce, null: false
      t.datetime :created_at, null: false
    end

    add_index :runner_request_nonces, [ :runner_enrollment_id, :nonce ], unique: true
    add_index :runner_request_nonces, :created_at
  end

end
