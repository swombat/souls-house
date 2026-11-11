# Nobody loses anything when features move from the resident to the account
# (2026-11-10). Each account is granted the plan that keeps what its
# residents and members have today:
#
#   - the highest resident tier whose entitlement is in force (active, grace
#     or complimentary): conversation → companions, life → partners,
#     work → colleagues;
#   - at least partners if it has more than one confirmed member;
#   - colleagues if any of its residents has sub-agents today (a Work plan in
#     force, a complimentary entitlement, or, by the old rule, no entitlement
#     and no birth order: a resident on the house).
#
# Companions is left as null (the default). A grant already set is only ever
# raised. The house-model allowance, now one per account and shared by its
# standard-rate residents, needs no backfill: it is worked out from the
# residents' entitlements when a call is made.
#
# Plain SQL and local stubs only: app models change after this runs.
class BackfillAccountPlans < ActiveRecord::Migration[8.1]

  ORDER = %w[companions partners colleagues].freeze
  TIER_PLAN = { "conversation" => "companions", "life" => "partners", "work" => "colleagues" }.freeze
  IN_FORCE_STATES = %w[active grace complimentary].freeze

  # The plan an account is granted, or nil for companions. Pure, so the
  # mapping is testable on its own.
  def self.plan_for(tiers:, confirmed_members:, subagents:, granted: nil)
    plans = tiers.map { |tier| TIER_PLAN[tier] }.compact
    plans << "partners" if confirmed_members > 1
    plans << "colleagues" if subagents
    plans << granted if ORDER.include?(granted)
    plan = plans.max_by { |id| ORDER.index(id) } || "companions"
    plan == "companions" ? nil : plan
  end

  def up
    in_force = IN_FORCE_STATES.map { |state| connection.quote(state) }.join(", ")
    rows = select_rows(<<~SQL)
      SELECT accounts.id, accounts.granted_plan,
        ARRAY(SELECT DISTINCT e.tier FROM resident_entitlements e
              WHERE e.account_id = accounts.id AND e.state IN (#{in_force}) AND e.tier IS NOT NULL),
        (SELECT COUNT(*) FROM memberships m WHERE m.account_id = accounts.id AND m.confirmed_at IS NOT NULL),
        EXISTS (
          SELECT 1 FROM agents a
          LEFT JOIN resident_entitlements e ON e.agent_id = a.id
          WHERE a.account_id = accounts.id AND (
            (e.id IS NULL AND NOT EXISTS (SELECT 1 FROM resident_birth_orders o WHERE o.agent_id = a.id))
            OR e.state = 'complimentary' OR e.complimentary_granted_at IS NOT NULL
            OR (e.tier = 'work' AND e.state IN (#{in_force}))
          )
        )
      FROM accounts
    SQL

    rows.each do |id, granted, tiers, members, subagents|
      plan = self.class.plan_for(tiers: decode_array(tiers), confirmed_members: members.to_i,
        subagents: ActiveModel::Type::Boolean.new.cast(subagents), granted: granted)
      next if plan.nil? || plan == granted

      execute "UPDATE accounts SET granted_plan = #{connection.quote(plan)} WHERE id = #{Integer(id)}"
    end
  end

  def down
    # Grants made here can't be told apart from a site admin's.
  end

  private

  # select_rows may return a Postgres array as a Ruby array or as "{a,b}".
  def decode_array(value)
    return value if value.is_a?(Array)

    value.to_s.delete("{}").split(",").map { |item| item.delete('"') }.reject(&:blank?)
  end

end
