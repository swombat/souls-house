# Guest integration grants (JWblqj): a connection in one house shared with a
# resident that is a guest there, approved by the resident's home. The access
# row keeps the request state; the events table keeps every transition.
class AddHomeApprovalToAgentServiceAccesses < ActiveRecord::Migration[8.1]

  def change
    change_table :agent_service_accesses do |t|
      # not_required for residents hosted where the connection lives (every
      # row so far); pending / approved / declined / revoked / withdrawn /
      # expired for a guest's row (AgentServiceAccess::HOME_APPROVALS).
      t.string :home_approval, null: false, default: "not_required"
      t.datetime :home_approval_requested_at
      t.datetime :home_approval_at
      t.references :home_approval_by, foreign_key: { to_table: :users, on_delete: :nullify }
      # Bumped on every request, so a decision names the request it saw.
      t.integer :home_approval_generation, null: false, default: 0
      # What was asked for: owner, Google identity, scopes, sending. A change
      # to any of it voids the approval.
      t.jsonb :home_approval_authority, null: false, default: {}
    end
    add_index :agent_service_accesses, [ :home_approval, :home_approval_requested_at ],
              name: "idx_agent_service_accesses_home_approval"

    create_table :guest_access_approval_events do |t|
      t.references :service_connection, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor_user, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :action, null: false
      t.string :reason
      t.integer :generation, null: false
      t.datetime :created_at, null: false
    end
    add_index :guest_access_approval_events, [ :agent_id, :service_connection_id, :created_at ],
              name: "idx_guest_access_approval_events_access_time"
  end

end
