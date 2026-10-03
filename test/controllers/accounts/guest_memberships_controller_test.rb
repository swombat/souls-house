require "test_helper"

class Accounts::GuestMembershipsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @daniel = users(:user_1)
    @team_member = users(:existing_user)
    @home = accounts(:personal_account)
    @nexus = accounts(:team_account)
    @lume = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
  end

  test "residents page offers residents from your other accounts" do
    sign_in @daniel
    get account_agents_path(@nexus)

    assert_response :success
    names = inertia_shared_props["guest_candidates"].map { |candidate| candidate["name"] }
    assert_includes names, @lume.name
  end

  test "someone in both accounts adds a guest" do
    sign_in @daniel
    assert_difference -> { @nexus.guest_memberships.count }, 1 do
      post account_guest_memberships_path(@nexus), params: { agent_id: @lume.to_param }
    end
    assert_redirected_to account_agents_path(@nexus)
    assert_equal @daniel, @nexus.guest_memberships.last.added_by
  end

  test "someone outside the resident's home cannot add it, even knowing its id" do
    sign_in @team_member
    assert_no_difference -> { GuestMembership.count } do
      post account_guest_memberships_path(@nexus), params: { agent_id: @lume.to_param }
    end
    assert_redirected_to account_agents_path(@nexus)
  end

  test "an owner of the receiving account removes a guest they did not add" do
    membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    nexus_owner = users(:regular_user)
    @nexus.memberships.create!(user: nexus_owner, role: "owner", confirmed_at: Time.current)
    sign_in nexus_owner

    delete account_guest_membership_path(@nexus, membership)

    assert_redirected_to account_agents_path(@nexus)
    assert_not GuestMembership.exists?(membership.id)
  end

  test "a plain member of the receiving account cannot remove a guest" do
    membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    sign_in @team_member

    delete account_guest_membership_path(@nexus, membership)

    assert GuestMembership.exists?(membership.id)
  end

  test "the home account withdraws its resident" do
    membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    sign_in @daniel

    delete account_guest_membership_path(@home, membership)

    assert_not GuestMembership.exists?(membership.id)
  end

  test "an unrelated account cannot reach the membership" do
    membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    sign_in @team_member

    delete account_guest_membership_path(accounts(:another_team), membership)

    assert GuestMembership.exists?(membership.id)
  end

  test "a receiving-account member who could not add the guest still seats it in a room" do
    @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    local = agents(:other_account_agent)
    room = @nexus.chats.create!(model_id: "openrouter/auto", title: "Field film", manual_responses: true, agents: [ local ])
    sign_in @team_member

    post account_chat_participant_path(@nexus, room), params: { agent_id: @lume.to_param }
    assert_includes room.agents.reload, @lume

    post account_chat_participant_path(@nexus, room), params: { agent_id: agents(:code_reviewer).to_param }
    assert_not_includes room.agents.reload, agents(:code_reviewer), "a home resident who is not a guest stays out"
  end

end
