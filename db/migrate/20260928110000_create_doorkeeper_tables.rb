class CreateDoorkeeperTables < ActiveRecord::Migration[8.0]

  # Native-app sign-in (issue #94, PR A): OAuth authorization code + PKCE for
  # public first-party clients. `app_sessions` is the signed-in device: every
  # token in one refresh chain shares it, and revoking it revokes the chain.
  def change
    create_table :oauth_applications do |t|
      t.string :name, null: false
      t.string :uid, null: false
      t.string :secret # public clients have none
      t.text :redirect_uri, null: false
      t.string :scopes, null: false, default: ""
      t.boolean :confidential, null: false, default: false
      t.timestamps
    end
    add_index :oauth_applications, :uid, unique: true

    create_table :app_sessions do |t|
      t.references :user, null: false, foreign_key: true
      t.references :oauth_application, null: false, foreign_key: true
      t.string :device_label
      t.datetime :last_used_at
      t.datetime :revoked_at
      t.string :revocation_reason
      t.timestamps
    end

    create_table :oauth_access_grants do |t|
      t.references :resource_owner, null: false, foreign_key: { to_table: :users }
      t.references :application, null: false, foreign_key: { to_table: :oauth_applications }
      t.string :token, null: false
      t.integer :expires_in, null: false
      t.text :redirect_uri, null: false
      t.string :scopes, null: false, default: ""
      t.string :code_challenge
      t.string :code_challenge_method
      t.string :device_label
      t.datetime :created_at, null: false
      t.datetime :revoked_at
    end
    add_index :oauth_access_grants, :token, unique: true

    create_table :oauth_access_tokens do |t|
      t.references :resource_owner, null: false, foreign_key: { to_table: :users }
      t.references :application, null: false, foreign_key: { to_table: :oauth_applications }
      t.references :app_session, null: false, foreign_key: true
      t.string :token, null: false
      t.string :refresh_token
      t.integer :expires_in
      t.string :scopes
      t.string :device_label
      t.string :previous_refresh_token, null: false, default: ""
      t.datetime :created_at, null: false
      t.datetime :revoked_at
    end
    add_index :oauth_access_tokens, :token, unique: true
    add_index :oauth_access_tokens, :refresh_token, unique: true
  end

end
