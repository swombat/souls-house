require "test_helper"

# The conversation menu's "Show commitments" (ChatsController#commitments).
class Chats::ConversationCommitmentsTest < ActionDispatch::IntegrationTest

  setup do
    @user = users(:user_1)
    @account = accounts(:personal_account)
    @agent = agents(:research_assistant)
    Setting.instance.update!(allow_agents: true)
    @chat = @account.chats.new(title: "Commitments here", manual_responses: true)
    @chat.agents = [ @agent ]
    @chat.save!
    @other_chat = @account.chats.new(title: "Elsewhere", manual_responses: true)
    @other_chat.agents = [ @agent ]
    @other_chat.save!
    post login_path, params: { email_address: @user.email_address, password: "password123" }
  end

  test "lists this conversation's commitments, outstanding soonest first, finished ones apart" do
    later = Commitment.create!(agent: @agent, source_chat: @chat, text: "Check the deploy receipt", summary: "Deploy receipt", due_at: 3.hours.from_now)
    sooner = Commitment.create!(agent: @agent, source_chat: @chat, text: "Look at the night sweep", due_at: 1.hour.from_now)
    done = Commitment.create!(agent: @agent, source_chat: @chat, text: "An older promise", due_at: 2.hours.from_now)
    done.cancel!(by: @user)
    Commitment.create!(agent: @agent, source_chat: @other_chat, text: "Not this conversation", due_at: 1.hour.from_now)

    get commitments_account_chat_path(@account, @chat), as: :json

    assert_response :success
    body = response.parsed_body
    assert_equal [ sooner.to_param, later.to_param ], body.dig("outstanding", "items").map { |item| item["id"] }
    assert_equal [ done.to_param ], body.dig("finished", "items").map { |item| item["id"] }
    assert_equal [ 2, 0, 1 ], body.values_at("outstanding", "blocked", "finished").map { |list| list["total"] }
    first = body.dig("outstanding", "items").last
    assert_equal [ "Deploy receipt", "Check the deploy receipt", @agent.name ], first.values_at("headline", "text", "resident_name")
    assert_equal edit_account_agent_path(@account, @agent, tab: "commitments"), first["manage_url"]
  end

  test "a member who does not own the house sees them but gets no manage link" do
    team = accounts(:team_account)
    member = User.find(memberships(:team_member).user_id)
    resident = team.agents.create!(name: "Teammate", system_prompt: "Test", runtime: "external")
    chat = team.chats.new(title: "Team", manual_responses: true)
    chat.agents = [ resident ]
    chat.save!
    Commitment.create!(agent: resident, source_chat: chat, text: "Team check", due_at: 1.hour.from_now)

    post login_path, params: { email_address: member.email_address, password: "password123" }
    get commitments_account_chat_path(team, chat), as: :json

    item = response.parsed_body.dig("outstanding", "items").sole
    assert_equal "Team check", item["text"]
    assert_nil item["manage_url"]
  end

  test "an empty conversation answers with empty lists, and another house's conversation is not found" do
    get commitments_account_chat_path(@account, @chat), as: :json
    empty = { "items" => [], "total" => 0 }
    assert_equal({ "outstanding" => empty, "blocked" => empty, "finished" => empty }, response.parsed_body)

    team = accounts(:team_account)
    resident = team.agents.create!(name: "Theirs", system_prompt: "Test", runtime: "external")
    outsider_chat = team.chats.new(title: "Not mine", manual_responses: true)
    outsider_chat.agents = [ resident ]
    outsider_chat.save!
    get commitments_account_chat_path(@account, outsider_chat), as: :json
    assert_response :not_found
  end

  test "a posted commitment whose wake is still in custody stays outstanding; blocked and delivered are kept apart" do
    held = Commitment.create!(agent: @agent, source_chat: @chat, text: "Held wake", due_at: 1.hour.from_now)
    retrying = Commitment.create!(agent: @agent, source_chat: @chat, text: "Retrying wake", due_at: 2.hours.from_now)
    blocked = Commitment.create!(agent: @agent, source_chat: @chat, text: "Blocked wake", due_at: 3.hours.from_now)
    delivered = Commitment.create!(agent: @agent, source_chat: @chat, text: "Delivered wake", due_at: 4.hours.from_now)
    legacy = Commitment.create!(agent: @agent, source_chat: @chat, text: "Posted before wakes were tracked", due_at: 5.hours.from_now)
    { held => "held", retrying => "retrying", blocked => "blocked", delivered => "delivered", legacy => nil }.each do |commitment, state|
      commitment.update_columns(status: "activated", activated_at: Time.current, wake_state: state)
    end

    get commitments_account_chat_path(@account, @chat), as: :json

    body = response.parsed_body
    assert_equal [ held, retrying ].map(&:to_param), body.dig("outstanding", "items").map { |item| item["id"] }
    assert_equal [ blocked.to_param ], body.dig("blocked", "items").map { |item| item["id"] }
    assert_equal [ legacy, delivered ].map(&:to_param), body.dig("finished", "items").map { |item| item["id"] }
    held_item = body.dig("outstanding", "items").first
    assert held_item["cancellable"]
    assert_equal edit_account_agent_path(@account, @agent, tab: "commitments"), held_item["manage_url"]
  end

end
