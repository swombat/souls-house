require "test_helper"

class Agents::CommitmentsControllerTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
    @chat = @account.chats.new(title: "Commitments", manual_responses: true)
    @chat.agents = [ @agent ]
    @chat.save!
    @commitment = Commitment.create!(agent: @agent, source_chat: @chat, text: "Look at the receipt", due_at: 1.hour.from_now)
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "the resident page lists commitments with what the owner may do" do
    assert @account.owned_by?(@user)
    get edit_account_agent_path(@account, @agent, tab: "commitments")
    item = inertia_shared_props.dig("commitments", "items").sole
    assert_equal [ @commitment.to_param, "Look at the receipt", "scheduled" ], item.values_at("id", "text", "status")
    assert_equal account_agent_commitment_path(@account, @agent, @commitment), item["manage_url"]
    assert_equal account_chat_path(@account, @chat), item["source_url"]
  end

  test "the owner reschedules and cancels; a finished commitment cannot be changed" do
    later = 3.hours.from_now.change(usec: 0)
    patch account_agent_commitment_path(@account, @agent, @commitment), params: { due_at: later.utc.iso8601 }
    assert_redirected_to edit_account_agent_path(@account, @agent, tab: "commitments")
    assert_equal later, @commitment.reload.due_at

    patch account_agent_commitment_path(@account, @agent, @commitment), params: { due_at: "yesterday" }
    assert_equal later, @commitment.reload.due_at

    delete account_agent_commitment_path(@account, @agent, @commitment)
    assert_equal [ "cancelled", @user ], [ @commitment.reload.status, @commitment.cancelled_by_user ]
    assert_nil inertia_after_redirect_manage_url
  end

  test "a member who does not own the house sees commitments but cannot manage them" do
    team = accounts(:team_account)
    member = User.find(memberships(:team_member).user_id)
    resident = team.agents.create!(name: "Teammate", system_prompt: "Test", runtime: "external")
    chat = team.chats.new(title: "Team", manual_responses: true)
    chat.agents = [ resident ]
    chat.save!
    commitment = Commitment.create!(agent: resident, source_chat: chat, text: "Team check", due_at: 1.hour.from_now)
    assert_not team.owned_by?(member)

    post login_path, params: { email_address: member.email_address, password: "password123" }
    get edit_account_agent_path(team, resident, tab: "commitments")
    item = inertia_shared_props.dig("commitments", "items").sole
    assert_equal "Team check", item["text"]
    assert_nil item["manage_url"]
    delete account_agent_commitment_path(team, resident, commitment)
    assert_response :forbidden
    assert commitment.reload.scheduled?
  end

  test "a host owner sees and manages a guest's commitments made here, and nothing else about it" do
    guest = agents(:other_account_agent)
    GuestMembership.create!(account: @account, agent: guest, added_by: @user)
    chat = @account.chats.new(title: "Hosted", manual_responses: true)
    chat.agents = [ guest ]
    chat.save!
    here = Commitment.create!(agent: guest, source_chat: chat, text: "Guest check", due_at: 1.hour.from_now)
    home_chat = guest.account.chats.new(title: "Home", manual_responses: true)
    home_chat.agents = [ guest ]
    home_chat.save!
    Commitment.create!(agent: guest, source_chat: home_chat, text: "Home only", due_at: 1.hour.from_now)

    get account_agent_commitments_path(@account, guest)
    assert_response :success
    items = inertia_shared_props.dig("commitments", "items")
    assert_equal [ "Guest check" ], items.pluck("text")
    assert_equal account_agent_commitment_path(@account, guest, here), items.sole["manage_url"]
    assert_equal true, inertia_shared_props.dig("agent", "guest")

    delete account_agent_commitment_path(@account, guest, here)
    assert_redirected_to account_agent_commitments_path(@account, guest)
    assert here.reload.cancelled?

    # The guest's settings stay closed to the host.
    get edit_account_agent_path(@account, guest)
    assert_response :not_found
  end

  test "after a guest leaves, the host still sees and can cancel what it committed to here" do
    guest = agents(:other_account_agent)
    membership = GuestMembership.create!(account: @account, agent: guest, added_by: @user)
    chat = @account.chats.new(title: "Hosted", manual_responses: true)
    chat.agents = [ guest ]
    chat.save!
    here = Commitment.create!(agent: guest, source_chat: chat, text: "Left behind", due_at: 1.hour.from_now)
    membership.destroy!

    get account_agents_path(@account)
    former = inertia_shared_props["former_guests_with_commitments"]
    assert_equal [ [ guest.to_param, account_agent_commitments_path(@account, guest) ] ], former.map { |f| f.values_at("id", "commitments_url") }

    get account_agent_commitments_path(@account, guest)
    assert_response :success
    assert_equal [ "Left behind" ], inertia_shared_props.dig("commitments", "items").pluck("text")
    delete account_agent_commitment_path(@account, guest, here)
    assert here.reload.cancelled?
    get edit_account_agent_path(@account, guest)
    assert_response :not_found
  end

  test "a resident from elsewhere that is not a guest here is not found" do
    get account_agent_commitments_path(@account, agents(:other_account_agent))
    assert_response :not_found
  end

  private

  def inertia_after_redirect_manage_url
    get edit_account_agent_path(@account, @agent, tab: "commitments")
    inertia_shared_props.dig("commitments", "items").sole["manage_url"]
  end

end
