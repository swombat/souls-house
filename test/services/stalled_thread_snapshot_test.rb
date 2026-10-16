require "test_helper"

class StalledThreadSnapshotTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @person = users(:user_1)
    @chat = @lume.account.chats.create!(title: "Sweeper", manual_responses: true, agents: [ @lume, @mira ])
    @t0 = 3.hours.ago.change(usec: 0)
  end

  test "nothing created after the sweep time is read" do
    post(@person, "Please build it.", at: @t0)
    post(@lume, "On it, I'll post the PR here.", at: @t0 + 1.minute)
    post(@person, "So?", at: @t0 + 2.hours)

    state = StalledThreadSnapshot.new(@chat, at: @t0 + 31.minutes).state

    assert_equal [ "Please build it.", "On it, I'll post the PR here." ], state[:recent_messages].pluck(:content)
    assert_equal 30, state[:minutes_since_last_message]
    assert_equal false, state[:last_human_message_after_last_resident_message]
    assert_equal [ "person", "resident" ], state[:recent_messages].pluck(:author_kind)
  end

  test "the window is the last three speaker-runs, and an earlier human message is kept beside it" do
    post(@person, "Build the sweeper.", at: @t0)
    post(@lume, "Spec posted.", at: @t0 + 1.minute)
    post(@mira, "Review one.", at: @t0 + 2.minutes)
    post(@mira, "Review two.", at: @t0 + 3.minutes)
    post(@lume, "Fixed.", at: @t0 + 4.minutes)
    post(@mira, "Approved.", at: @t0 + 5.minutes)

    state = StalledThreadSnapshot.new(@chat, at: @t0 + 1.hour).state

    assert_equal [ "Review one.", "Review two.", "Fixed.", "Approved." ], state[:recent_messages].pluck(:content)
    assert_equal "Build the sweeper.", state[:last_human_message_before_window][:content]
  end

  test "historical pause state is unknown; a live snapshot reads it" do
    post(@lume, "Done.", at: @t0)
    @mira.update_columns(paused: true)

    historical = StalledThreadSnapshot.new(@chat, at: @t0 + 10.minutes).state[:residents_in_room]
    live = StalledThreadSnapshot.new(@chat, at: Time.current, live: true).state[:residents_in_room]

    assert_equal [ "unknown" ], historical.pluck(:paused).uniq
    assert_equal true, live.find { |r| r[:name] == @mira.name }[:paused]
  end

  test "a handoff is reported as it stood at the sweep time" do
    message = post(@lume, "Mira, ready for review.", at: @t0)
    handoff = MessageHandoff.create!(
      message: message, chat: @chat, requester_agent: @lume, recipient_agent: @mira,
      source: "field", status: "delivered", delivered_at: @t0 + 40.minutes
    )
    handoff.update_columns(created_at: @t0)

    before = StalledThreadSnapshot.new(@chat, at: @t0 + 30.minutes).state
    after = StalledThreadSnapshot.new(@chat, at: @t0 + 50.minutes).state

    assert_equal [ { to: @mira.name, state: "requested" } ], before[:recent_messages].last[:handoffs]
    assert_equal [ { to: @mira.name, state: "delivered" } ], after[:recent_messages].last[:handoffs]
  end

  test "an empty room has no snapshot" do
    assert_nil StalledThreadSnapshot.new(@chat, at: Time.current).state
  end

  private

  def post(author, content, at:)
    attributes = author.is_a?(Agent) ? { role: "assistant", agent: author } : { role: "user", user: author }
    message = @chat.messages.create!(content: content, **attributes)
    message.update_columns(created_at: at, updated_at: at)
    message
  end

end
