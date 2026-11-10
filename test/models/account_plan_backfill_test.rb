require "test_helper"
require Rails.root.join("db/migrate/20261110180100_backfill_account_plans")

# Nobody loses anything when features move from the resident to the account.
class AccountPlanBackfillTest < ActiveSupport::TestCase

  def plan_for(...) = BackfillAccountPlans.plan_for(...)

  test "the mapping: the highest tier in force, raised by members and sub-agents, companions left null" do
    assert_nil plan_for(tiers: [], confirmed_members: 1, subagents: false)
    assert_nil plan_for(tiers: %w[conversation], confirmed_members: 1, subagents: false)
    assert_equal "partners", plan_for(tiers: %w[life], confirmed_members: 1, subagents: false)
    assert_equal "colleagues", plan_for(tiers: %w[work], confirmed_members: 1, subagents: false)
    assert_equal "colleagues", plan_for(tiers: %w[conversation work life], confirmed_members: 1, subagents: false)
    assert_equal "partners", plan_for(tiers: %w[conversation], confirmed_members: 2, subagents: false)
    assert_equal "partners", plan_for(tiers: [], confirmed_members: 3, subagents: false)
    assert_equal "colleagues", plan_for(tiers: %w[life], confirmed_members: 2, subagents: true)
    assert_equal "colleagues", plan_for(tiers: [], confirmed_members: 1, subagents: true)
    assert_equal "colleagues", plan_for(tiers: [], confirmed_members: 1, subagents: false, granted: "colleagues"),
      "an existing grant is never lowered"
    assert_nil plan_for(tiers: %w[bogus], confirmed_members: 0, subagents: false)
  end

  def backfill! = ActiveRecord::Migration.suppress_messages { BackfillAccountPlans.new.up }

  test "against the database: tiers in force, confirmed members and today's sub-agent rule" do
    Account.update_all(granted_plan: nil)
    personal = accounts(:personal_account) # residents with no entitlement: on the house, so sub-agents today
    team = accounts(:team_account)         # two confirmed members, a resident with a birth order
    single = accounts(:team_single_user)   # nobody but its owner
    ResidentBirthOrder.create!(account: team, creator: users(:user_1), tier: "conversation", state: "born",
      agent: agents(:other_account_agent))
    Membership.where(account: team).update_all(confirmed_at: 1.day.ago)

    backfill!

    assert_equal "colleagues", personal.reload.granted_plan
    assert_equal "partners", team.reload.granted_plan
    assert_nil single.reload.granted_plan
  end

  test "a held or pending plan doesn't count; one in force does" do
    Account.update_all(granted_plan: nil)
    team = accounts(:team_account)
    Membership.where(account: team).where.not(role: "owner").delete_all
    agent = agents(:other_account_agent)
    entitlement = ResidentEntitlement.create!(agent: agent, account: team, source: "stripe", state: "held", tier: "work")
    backfill!
    assert_nil team.reload.granted_plan

    entitlement.update_columns(state: "active", tier: "life")
    backfill!
    assert_equal "partners", team.reload.granted_plan

    entitlement.update_columns(state: "active", tier: "work")
    backfill!
    assert_equal "colleagues", team.reload.granted_plan
  end

end
