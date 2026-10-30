# Residents born after the 11 Oct billing migration in accounts that don't pay
# per resident had no entitlement at all. They get free hosting like the
# residents before them, which now carries a $10 monthly house-model allowance
# of its own (Daniel, jygXOY/jlnVNY, 2026-10-30). A resident in such an
# account whose only entitlement is a checkout it never completed (pending, no
# current subscription) is also on free hosting; it keeps its checkout
# metadata, so a checkout completed later still activates the plan. Paid,
# grace and held entitlements, and accounts that pay per resident, are
# untouched.
class BackfillFreeHostingEntitlements < ActiveRecord::Migration[8.1]

  def up
    execute <<~SQL
      INSERT INTO resident_entitlements
        (agent_id, account_id, source, state, rate, complimentary_granted_at, notices_sent, created_at, updated_at)
      SELECT agents.id, agents.account_id, 'complimentary', 'complimentary', 'standard', NOW(), '{}'::jsonb, NOW(), NOW()
      FROM agents
      JOIN accounts ON accounts.id = agents.account_id
      WHERE agents.runtime IN ('external', 'offline', 'provisioning')
        AND accounts.billing_required = FALSE
        AND NOT EXISTS (SELECT 1 FROM resident_entitlements e WHERE e.agent_id = agents.id)
    SQL

    execute <<~SQL
      UPDATE resident_entitlements
      SET state = 'complimentary', source = 'complimentary', complimentary_granted_at = NOW(), updated_at = NOW()
      FROM agents, accounts
      WHERE agents.id = resident_entitlements.agent_id
        AND accounts.id = agents.account_id
        AND agents.runtime IN ('external', 'offline', 'provisioning')
        AND accounts.billing_required = FALSE
        AND resident_entitlements.state = 'pending'
        AND resident_entitlements.current_subscription_id IS NULL
    SQL
  end

  def down
    # Rows created here can't be told apart from later free-hosting grants.
  end

end
