require "test_helper"

# The away seats in the Guest residents card carry the rhythms the resident
# has in the account it visits and the runs it has going there (JwMzAe).
class Agents::AwaySeatsTest < ActiveSupport::TestCase

  setup do
    @daniel = users(:user_1)
    @home = accounts(:personal_account)
    @visited = accounts(:team_account)
    @lume = agents(:research_assistant)
    @seat = @visited.guest_memberships.create!(agent: @lume, added_by: @daniel)
    @routes = Rails.application.routes.url_helpers
  end

  test "counts the visited account's rhythms that include the resident, not its home rhythms or others'" do
    rhythm(@visited, [ @lume ])
    rhythm(@visited, [ @lume ])
    rhythm(@home, [ @lume ])
    other = Agent.create!(account: @visited, name: "Host", model_id: "openrouter/auto")
    rhythm(@visited, [ other ])

    assert_equal 2, row.dig(:rhythms, :count)
  end

  test "no rhythms is zero" do
    assert_equal 0, row.dig(:rhythms, :count)
  end

  test "the link to the visited account's rhythms is offered only to its members" do
    rhythm(@visited, [ @lume ])
    member = User.create!(email_address: "member-#{SecureRandom.hex(4)}@example.test")
    @visited.memberships.create!(user: member, role: "member", confirmed_at: Time.current)
    stranger = User.create!(email_address: "stranger-#{SecureRandom.hex(4)}@example.test")

    assert_equal @routes.account_rhythms_path(@visited), row(user: member).dig(:rhythms, :url)
    assert_nil row(user: stranger).dig(:rhythms, :url)
  end

  test "sessions count only runs in the visited account's conversations" do
    there = @visited.chats.create!(title: "There", manual_responses: true, agents: [ @lume ])
    home = @home.chats.create!(title: "Home", manual_responses: true, agents: [ @lume ])
    start_run(@lume, there)
    start_run(@lume, there)
    start_run(@lume, home)
    start_run(@lume, nil)

    sessions = seats.sessions
    assert_equal({ chat: 2, telegram: 0, other: 0 }, sessions.fetch(@seat.to_param))
    assert_equal 1, sessions.size
  end

  test "a finished run is not counted" do
    there = @visited.chats.create!(title: "There", manual_responses: true, agents: [ @lume ])
    start_run(@lume, there, state: "completed")

    assert_equal({}, seats.sessions)
  end

  private

  def seats(user: @daniel)
    Agents::AwaySeats.new([ @seat ], user: user, routes: @routes)
  end

  def row(user: @daniel)
    seats(user: user).with_rhythms([ @seat.as_json ]).sole
  end

  def rhythm(account, agents)
    Rhythm.create!(account: account, creator: @daniel, title: "Look #{SecureRandom.hex(3)}", opening: "What is there?",
      agents: agents, cadence: "daily", time_of_day: "09:00", timezone: "UTC", next_run_at: 1.day.from_now)
  end

  def start_run(agent, chat, state: "running")
    AgentRuntimeInteraction.create!(agent: agent, chat: chat, trigger_kind: chat ? "conversation" : "wake",
      started_at: Time.current, run_id: SecureRandom.uuid, execution_state: state)
  end

end
