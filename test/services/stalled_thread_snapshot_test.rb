require "test_helper"

class StalledThreadSnapshotTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @person = users(:user_1)
    @chat = @lume.account.chats.create!(title: "Sweeper", manual_responses: true, agents: [ @lume, @mira ])
    @t0 = 3.hours.ago.change(usec: 0)
    @chat.chat_agents.update_all(created_at: 1.day.ago)
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

  test "a sweep time is strictly inside its gap, so the next message never enters the snapshot" do
    assert_nil StalledThreadSnapshot.sweep_offset(10.minutes)
    assert_equal 10.minutes, StalledThreadSnapshot.sweep_offset(30.minutes)
    assert_equal 30.minutes, StalledThreadSnapshot.sweep_offset(60.minutes)
    assert_equal 60.minutes, StalledThreadSnapshot.sweep_offset(60.minutes + 1.second)

    before = post(@lume, "Before the gap.", at: @t0)
    post(@person, "After the gap.", at: @t0 + 30.minutes)
    snapshot = StalledThreadSnapshot.new(@chat, at: @t0 + StalledThreadSnapshot.sweep_offset(30.minutes))

    assert_equal before, snapshot.last_message
  end

  test "an empty room has no snapshot" do
    assert_nil StalledThreadSnapshot.new(@chat, at: Time.current).state
  end

  test "a message discarded after the sweep time is still shown; one discarded before it is not" do
    post(@person, "Kept.", at: @t0)
    later = post(@lume, "Discarded later.", at: @t0 + 1.minute)
    earlier = post(@mira, "Discarded at once.", at: @t0 + 2.minutes)
    later.update_columns(discarded_at: @t0 + 2.hours)
    earlier.update_columns(discarded_at: @t0 + 3.minutes)

    snapshot = StalledThreadSnapshot.new(@chat, at: @t0 + 30.minutes)

    assert_equal [ "Kept.", "Discarded later." ], snapshot.state[:recent_messages].pluck(:content)
    assert_equal [ "Kept." ], StalledThreadSnapshot.new(@chat, at: Time.current, live: true).state[:recent_messages].pluck(:content)
  end

  test "text that changed after the sweep time is flagged in provenance, outside the state" do
    post(@person, "Please build it.", at: @t0)
    edited = post(@lume, "On it.", at: @t0 + 1.minute)
    edited.update_columns(content: "On it. (edited later)", updated_at: @t0 + 3.hours)

    snapshot = StalledThreadSnapshot.new(@chat, at: @t0 + 30.minutes)

    assert_equal [ edited.obfuscated_id ], snapshot.provenance[:content_unverified_ids]
    assert_not snapshot.state.key?(:provenance)
    assert_equal({ as_of: "live" }, StalledThreadSnapshot.new(@chat, at: Time.current, live: true).provenance)
  end

  test "a resident who joined after the sweep time is not in the room" do
    post(@person, "Hello.", at: @t0)
    @chat.chat_agents.find_by!(agent: @mira).update_columns(created_at: @t0 + 1.hour)
    @chat.chat_agents.find_by!(agent: @lume).update_columns(created_at: @t0 - 1.hour)

    names = StalledThreadSnapshot.new(@chat, at: @t0 + 30.minutes).state[:residents_in_room].pluck(:name)

    assert_equal [ @lume.name ], names
  end

  test "a long run crossing the sweep time is in progress; one with no recorded end is unknown" do
    post(@person, "Go.", at: @t0)
    record_run(@lume, started_at: @t0 - 3.hours, finished_at: @t0 + 2.hours)
    record_run(@mira, started_at: @t0 - 3.hours, finished_at: nil)

    residents = StalledThreadSnapshot.new(@chat, at: @t0 + 30.minutes).state[:residents_in_room].index_by { |r| r[:name] }

    assert_equal true, residents[@lume.name][:run_in_progress]
    assert_equal "unknown", residents[@mira.name][:run_in_progress]
    assert StalledThreadSnapshot.new(@chat, at: @t0 + 30.minutes).provenance[:run_state_unknown]
  end

  test "the message budget holds across many long messages" do
    12.times { |i| post(i.even? ? @lume : @mira, "#{i} #{'x' * 3_000}", at: @t0 + i.minutes) }

    state = StalledThreadSnapshot.new(@chat, at: @t0 + 1.hour).state

    assert_operator state[:recent_messages].sum { |m| m[:content].length }, :<=, StalledThreadSnapshot::TOTAL_CHARS
    assert state[:recent_messages_truncated]
  end

  private

  def record_run(agent, started_at:, finished_at:)
    AgentRuntimeInteraction.create!(
      agent: agent, chat: @chat, trigger_kind: "conversation", requested_by: "souls.house",
      started_at: started_at, finished_at: finished_at, execution_state: finished_at ? "completed" : nil
    )
  end

  def post(author, content, at:)
    attributes = author.is_a?(Agent) ? { role: "assistant", agent: author } : { role: "user", user: author }
    message = @chat.messages.create!(content: content, **attributes)
    message.update_columns(created_at: at, updated_at: at)
    message
  end

end
