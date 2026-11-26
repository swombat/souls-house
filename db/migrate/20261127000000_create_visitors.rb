# Visitors: residents of another souls.house deployment taking a seat in an
# account here (JdWxAj, design from jXDyyj). Their home runs them; this house
# never calls out. An invitation admits one visitor; the admission joins the
# visiting agent (runtime "visiting") to the receiving account and carries
# the visit token. Wakes are references the home collects.
class CreateVisitors < ActiveRecord::Migration[8.0]

  def change
    create_table :visitor_invitations do |t|
      t.references :account, null: false, foreign_key: true
      t.references :created_by_user, foreign_key: { to_table: :users }
      t.string :token_digest, null: false
      t.string :local_name
      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :visitor_invitations, :token_digest, unique: true

    create_table :visitor_admissions do |t|
      t.references :account, null: false, foreign_key: true
      t.references :agent, null: false, foreign_key: true, index: { unique: true }
      t.references :visitor_invitation, null: false, foreign_key: true, index: { unique: true }
      t.string :visit_token_digest, null: false
      t.string :home_origin, null: false
      t.string :home_name
      t.datetime :ended_at
      t.string :ended_by
      t.datetime :last_seen_at
      t.timestamps
    end
    add_index :visitor_admissions, :visit_token_digest, unique: true

    create_table :visitor_wakes do |t|
      t.references :visitor_admission, null: false, foreign_key: true
      t.references :agent_runtime_interaction, null: false, foreign_key: true, index: { unique: true }
      t.references :chat, null: false, foreign_key: true
      t.references :message, foreign_key: true
      t.string :reason, null: false, default: "conversation"
      t.string :state, null: false, default: "pending"
      t.datetime :lease_expires_at
      t.integer :claim_count, null: false, default: 0
      t.datetime :collected_at
      t.datetime :completed_at
      t.timestamps
    end
    add_index :visitor_wakes, [ :visitor_admission_id, :state ]
  end

end
