require "test_helper"

# Account#plan and the gates that moved from the resident to the account
# (2026-11-10): members, swarm searches, sub-agents.
class AccountPlanTest < ActiveSupport::TestCase

  setup do
    @team = accounts(:team_account)
    @team.update_columns(granted_plan: nil)
    @owner = users(:user_1)
  end

  def subscribe!(account, plan, status: "active", id: "sub_acct_#{account.id}_#{plan}", past_due_since: nil)
    AccountSubscription.create!(account: account, stripe_subscription_id: id, plan: plan, stripe_status: status,
      past_due_since: past_due_since)
  end

  test "Companions by default, from nobody" do
    assert_equal "companions", @team.plan.id
    assert_equal({ id: "companions", source: "default", subscription: nil }, @team.account_plan_json)
  end

  test "a site admin's grant is the plan when nothing is paid" do
    @team.update!(granted_plan: "partners")
    assert_equal "partners", @team.plan.id
    assert_equal "grant", @team.plan_source
  end

  test "an unknown grant is refused" do
    @team.granted_plan = "platinum"
    assert_not @team.valid?
    assert @team.errors[:granted_plan].any?
  end

  test "a paid subscription is the plan, and the higher of grant and subscription wins" do
    subscription = subscribe!(@team, "partners")
    assert_equal "partners", @team.plan.id
    assert_equal "subscription", @team.plan_source
    assert_equal({ status: "active", current_period_end: nil, cancel_at_period_end: false },
      @team.account_plan_json[:subscription])

    @team.update!(granted_plan: "colleagues")
    assert_equal "colleagues", @team.plan.id
    assert_equal "grant", @team.plan_source

    @team.update!(granted_plan: "partners")
    assert_equal "partners", @team.plan.id
    assert_equal "subscription", @team.plan_source, "they pay for what they'd be given anyway"

    subscription.update!(plan: "colleagues")
    assert_equal "colleagues", @team.plan.id
  end

  test "an unpaid subscription grants nothing; past_due holds the plan through the grace period only" do
    subscription = subscribe!(@team, "colleagues", status: "incomplete")
    assert_equal "companions", @team.plan.id
    assert_equal "default", @team.plan_source
    assert_equal "incomplete", @team.account_plan_json.dig(:subscription, :status), "the Billing tab still sees it"

    now = Time.current
    subscription.update!(stripe_status: "past_due", past_due_since: now)
    assert_equal "colleagues", @team.plan(now + 13.days).id
    assert_equal "companions", @team.plan(now + Billing::GRACE_PERIOD + 1.minute).id

    subscription.update!(stripe_status: "canceled", past_due_since: nil)
    assert_equal "companions", @team.plan.id
  end

  test "an ended subscription drops back to the grant" do
    @team.update!(granted_plan: "partners")
    subscribe!(@team, "colleagues", status: "canceled")
    assert_equal "partners", @team.plan.id
    assert_equal "grant", @team.plan_source
  end

  # Members ------------------------------------------------------------

  test "a Companions account can't invite or add a second member, and says to choose Partners" do
    @team.memberships.where.not(user: @owner).delete_all
    invitation = @team.send_invitation(email: "new-person@example.com", role: "member", invited_by: @owner)
    assert_not invitation.persisted?
    assert_includes invitation.errors.full_messages.to_sentence, "Partners plan"
    assert_not User.exists?(email_address: "new-person@example.com"), "a refused invitation leaves no user behind"

    assert_raises(ActiveRecord::RecordInvalid) { @team.add_user!(users(:existing_user), role: "member") }

    @team.memberships.build(user: users(:existing_user), role: "member", invited_by: @owner)
    assert_not @team.valid?
    assert_includes @team.errors[:base], Account::MEMBER_LIMIT_MESSAGE
  end

  test "on Partners or Colleagues an account takes several members" do
    @team.memberships.where.not(user: @owner).delete_all
    subscribe!(@team, "partners")
    invitation = @team.send_invitation(email: "new-person@example.com", role: "member", invited_by: @owner)
    assert invitation.persisted?
  end

  test "a new Companions account still gets its owner" do
    account = Account.create!(name: "Fresh team", account_type: :team)
    membership = account.add_user!(users(:existing_user), role: "owner", skip_confirmation: true)
    assert membership.persisted?
    assert_equal "companions", account.plan.id
  end

  test "dropping to Companions ejects nobody: members stay, new ones are refused" do
    @team.update!(granted_plan: "partners")
    @team.add_user!(users(:existing_user), role: "member", skip_confirmation: true) unless @team.memberships.exists?(user: users(:existing_user))
    members = @team.memberships.count
    assert_operator members, :>, 1

    @team.update!(granted_plan: nil)
    assert_equal "companions", @team.plan.id
    assert_equal members, @team.memberships.count
    assert @team.memberships.all? { |membership| membership.valid? }, "existing members stay valid"
    assert @team.reload.update(name: "Renamed team"), "the account itself still saves"
    invitation = @team.send_invitation(email: "another@example.com", role: "member", invited_by: @owner)
    assert_not invitation.persisted?
  end

  test "a Companions account can still bring a resident in as a guest; guests are not members" do
    home = accounts(:personal_account)
    resident = agents(:research_assistant)
    @team.memberships.where.not(user: @owner).delete_all
    @team.add_user!(@owner, role: "owner", skip_confirmation: true) unless @team.memberships.exists?(user: @owner)
    home.add_user!(@owner, role: "owner", skip_confirmation: true) unless home.memberships.exists?(user: @owner)
    assert_equal "companions", @team.plan.id
    members = @team.memberships.count

    guest = @team.guest_memberships.create!(agent: resident, added_by: @owner)
    assert guest.persisted?
    assert_includes @team.conversation_agents, resident
    assert_equal members, @team.memberships.count
  end

  # Swarm searches -------------------------------------------------------

  test "swarm searches are the account plan's, not a sum per resident" do
    @team.update!(field_swarm_enabled: false)
    agent = agents(:other_account_agent)
    ResidentEntitlement.create!(agent: agent, account: @team, source: "stripe", state: "active", tier: "work")
    assert_equal 0, @team.field_swarm_plan_searches, "a Large resident brings no searches"
    assert_not @team.field_swarm_allowed?

    @team.update!(granted_plan: "partners")
    assert_equal 20, @team.field_swarm_plan_searches
    assert_equal 20, @team.field_swarm_monthly_limit

    subscribe!(@team, "colleagues")
    assert_equal 100, @team.field_swarm_monthly_limit

    @team.update!(field_swarm_enabled: true)
    assert_nil @team.field_swarm_monthly_limit, "the admin switch still has only the daily cap"
  end

end
