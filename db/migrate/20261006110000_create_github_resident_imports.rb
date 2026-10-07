class CreateGithubResidentImports < ActiveRecord::Migration[8.1]

  def change
    create_table :github_resident_imports do |t|
      t.references :account, null: false, foreign_key: true
      t.references :service_connection, null: false, foreign_key: true
      t.references :requested_by, null: false, foreign_key: { to_table: :users }
      t.references :approved_by, foreign_key: { to_table: :users }
      t.string :name, null: false
      t.string :model_id, null: false
      t.string :repository, null: false
      t.string :repository_id, null: false
      t.string :branch, null: false
      t.string :commit_sha, null: false
      t.string :portable_home_id, null: false
      t.string :credential_fingerprint, null: false
      t.jsonb :token_metadata, default: {}, null: false
      t.string :status, default: "pending_review", null: false
      t.string :approved_commit_sha
      t.string :observed_branch_sha_at_approval
      t.string :approved_credential_fingerprint
      t.string :approved_image
      t.datetime :approved_at
      t.string :last_error
      t.timestamps
    end
    add_reference :agents, :github_resident_import, foreign_key: true, index: { unique: true }
  end

end
