require "test_helper"

class GuestMembershipTest < ActiveSupport::TestCase

  setup do
    @daniel = users(:user_1)            # in both the personal and team accounts
    @team_member = users(:existing_user) # in the team account, not the personal one
    @home = accounts(:personal_account)
    @nexus = accounts(:team_account)
    @lume = agents(:research_assistant)  # hosted in @home
    @local = agents(:other_account_agent) # hosted in @nexus
  end

  test "someone in both accounts brings a resident in; it then takes part like a local resident" do
    assert_includes GuestMembership.candidates_for(account: @nexus, user: @daniel), @lume

    @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)

    assert_includes @nexus.conversation_agents, @lume
    assert_includes @nexus.conversation_agents, @local
    assert_not_includes @nexus.agents, @lume, "hosting ownership does not move"
    assert_not_includes GuestMembership.candidates_for(account: @nexus, user: @daniel), @lume
  end

  test "someone outside the resident's home cannot bring it in" do
    assert_empty GuestMembership.candidates_for(account: @nexus, user: @team_member)

    membership = @nexus.guest_memberships.new(agent: @lume, added_by: @team_member)
    assert_not membership.valid?
  end

  test "a site admin is not treated as speaking for a home they don't belong to" do
    admin = users(:site_admin_user)
    @nexus.memberships.create!(user: admin, role: "member", confirmed_at: Time.current)

    assert_not_includes GuestMembership.candidates_for(account: @nexus, user: admin), @lume
    assert_not @nexus.guest_memberships.new(agent: @lume, added_by: admin).valid?
  end

  test "a resident cannot be a guest in its own home" do
    assert_not @home.guest_memberships.new(agent: @lume, added_by: @daniel).valid?
  end

  test "room pickers draw from residents hosted here plus guests" do
    assert_not_includes @nexus.conversation_agents.eligible_for_conversation, @lume

    @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    assert_includes @nexus.conversation_agents.eligible_for_conversation, @lume
    assert_not_includes @nexus.conversation_agents, agents(:code_reviewer), "other home residents stay out"
  end

  test "leaving closes seats in that account only and keeps what was said" do
    membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    guest_room = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @local, @lume ])
    guest_room.messages.create!(role: "assistant", agent: @lume, content: "Here, as a guest.")
    home_room = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @lume ])

    membership.destroy!

    assert_not guest_room.agents.reload.include?(@lume)
    assert guest_room.messages.exists?(agent: @lume, content: "Here, as a guest.")
    assert_match(/has left the conversation/, guest_room.messages.order(:id).last.content)
    assert home_room.agents.reload.include?(@lume)
    assert_not_includes @nexus.conversation_agents, @lume
  end

  test "a wake queued before leaving does not run after it" do
    membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    room = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @local, @lume ])
    membership.destroy!

    woken = false
    ExternalAgentResponseRequest.stub(:new, ->(**) { woken = true; flunk "a removed guest was woken" }) do
      ManualAgentResponseJob.perform_now(room, @lume)
    end
    assert_not woken
  end

  test "either side can end it" do
    membership = @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)

    assert membership.removable_by?(@team_member), "the receiving account"
    assert membership.removable_by?(@daniel), "the home account"
    assert_not membership.removable_by?(users(:regular_user))
  end

  test "the wake names the account and guest status only for guests" do
    @nexus.guest_memberships.create!(agent: @lume, added_by: @daniel)
    guest_room = @nexus.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @lume ])
    home_room = @home.chats.create!(model_id: "openrouter/auto", manual_responses: true, agents: [ @lume ])

    guest_text = ExternalAgentResponseRequest.new(agent: @lume, chat: guest_room).send(:conversation_metadata)
    home_text = ExternalAgentResponseRequest.new(agent: @lume, chat: home_room).send(:conversation_metadata)

    assert_match(/you are a guest here; your home account is #{Regexp.escape(@home.name)}/, guest_text)
    assert_includes guest_text, "- account: #{@nexus.name}"
    assert_no_match(/account:/, home_text)
  end

end
