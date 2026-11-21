# Which residents may post to their account's X handle. Until now every
# resident of an account with X posting switched on could post; X was not
# part of the per-resident integration switches. A row here is the switch.
#
# Backfill: only accounts that could actually post before this (a connected
# handle, with posting switched on) keep their current residents switched
# on, so nothing that worked stops working. Accounts with posting off, or
# with only an app set up, get no rows. Residents created from now on start
# without one.
class CreateXPostingGrants < ActiveRecord::Migration[8.1]

  def up
    create_table :x_posting_grants do |t|
      t.references :x_integration, null: false, foreign_key: { on_delete: :cascade }
      t.references :agent, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.timestamps
    end
    add_index :x_posting_grants, %i[agent_id x_integration_id], unique: true

    execute <<~SQL.squish
      INSERT INTO x_posting_grants (x_integration_id, agent_id, created_at, updated_at)
      SELECT x_integrations.id, agents.id, NOW(), NOW()
      FROM x_integrations
      JOIN agents ON agents.account_id = x_integrations.account_id
      WHERE x_integrations.enabled
        AND COALESCE(x_integrations.access_token, '') <> ''
        AND COALESCE(x_integrations.refresh_token, '') <> ''
    SQL
  end

  def down
    drop_table :x_posting_grants
  end

end
