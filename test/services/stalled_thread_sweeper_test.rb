require "test_helper"

class StalledThreadSweeperTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @person = users(:user_1)
    @chat = @lume.account.chats.create!(title: "Quiet room", manual_responses: true, agents: [ @lume, @mira ])
    @chat.chat_agents.update_all(created_at: 1.day.ago)
    @lume.account.update!(stalled_sweep_enabled: true)
    @now = Time.current.change(usec: 0)
  end

  test "off records nothing and asks nobody" do
    post(@lume, "Approved, merging once CI is green.", at: @now - 2.hours)

    assert_no_difference(-> { StalledThreadSweep.count }) do
      assert_equal [], sweeper(interval: nil, decide: ->(**) { flunk "off" }).call
    end
  end

  test "a quiet room is judged once per state and nothing is posted" do
    post(@person, "Please build it.", at: @now - 3.hours)
    last = post(@lume, "On it, I'll post the PR here.", at: @now - 2.hours)
    calls = 0
    decide = lambda do |state:, questions:|
      calls += 1
      assert_equal [ "can_act:1", "can_act:2", "person_holds" ], questions.keys
      { "can_act:1" => 0.9, "can_act:2" => 0.1, "person_holds" => 0.2 }
    end

    assert_no_difference(-> { Message.count }) do
      assert_no_difference(-> { AgentRuntimeInteraction.count }) do
        sweeper(decide: decide).call
        sweeper(decide: decide).call
      end
    end

    sweep = StalledThreadSweep.sole
    assert_equal 1, calls
    assert_equal last, sweep.message
    assert_equal "would_wake", sweep.outcome
    assert_equal [ @lume.name ], sweep.would_wake
    assert_equal [ @lume.to_param, @mira.to_param ], sweep.scores.pluck("agent_id")
    assert_equal 120, sweep.quiet_minutes
  end

  test "a new message makes a new state that is judged again" do
    post(@lume, "Done.", at: @now - 3.hours)
    quiet = ->(**) { { "can_act:1" => 0.1, "can_act:2" => 0.1, "person_holds" => 0.1 } }
    sweeper(decide: quiet).call
    post(@person, "Thanks, can you also check the docs?", at: @now - 1.hour)
    sweeper(decide: quiet).call

    assert_equal %w[quiet quiet], StalledThreadSweep.order(:id).pluck(:outcome)
  end

  test "rooms still inside the interval or with a run going are left alone" do
    post(@lume, "Just said this.", at: @now - 5.minutes)
    busy_room = room(@lume, "Busy", quiet_since: @now - 2.hours)
    AgentRuntimeInteraction.create!(agent: @lume, chat: busy_room, trigger_kind: "conversation", requested_by: "souls.house",
      started_at: 5.minutes.ago, execution_state: "running")

    sweeper(decide: ->(**) { flunk "nothing to judge" }).call

    assert_equal 0, StalledThreadSweep.count
  end

  test "a room quiet for four days is still judged" do
    post(@lume, "I'll merge once CI is green.", at: @now - 4.days)
    sweeper(decide: ->(**) { { "can_act:1" => 0.9, "can_act:2" => 0.1, "person_holds" => 0.1 } }).call
    assert_equal [ "would_wake", 4 * 24 * 60 ], StalledThreadSweep.sole.values_at(:outcome, :quiet_minutes)
  end

  test "busy rooms don't use the budget: an eligible room behind twenty-five busy ones is judged" do
    25.times do |i|
      busy = room(@lume, "Busy #{i}", quiet_since: @now - 1.hour - i.minutes)
      AgentRuntimeInteraction.create!(agent: @lume, chat: busy, trigger_kind: "conversation", requested_by: "souls.house",
        started_at: 5.minutes.ago, execution_state: "running")
    end
    post(@lume, "Waiting on review.", at: @now - 3.hours)

    2.times { sweeper(decide: ->(**) { { "can_act:1" => 0.1, "can_act:2" => 0.1, "person_holds" => 0.1 } }).call }

    assert_equal [ @chat ], StalledThreadSweep.all.map(&:chat)
  end

  test "only accounts that opted in are read" do
    post(@lume, "Done.", at: @now - 2.hours)
    other = agents(:other_account_agent)
    other_room = other.account.chats.create!(title: "Other account", manual_responses: true, agents: [ other ])
    other_room.chat_agents.update_all(created_at: 1.day.ago)
    other_room.messages.create!(role: "assistant", agent: other, content: "Private.").update_columns(created_at: @now - 2.hours)
    seen = []
    decide = lambda do |state:, questions:|
      seen << state[:recent_messages].pluck(:content)
      { "can_act:1" => 0.1, "can_act:2" => 0.1, "person_holds" => 0.1 }.slice(*questions.keys)
    end

    sweeper(decide: decide).call
    assert_equal [ @chat ], StalledThreadSweep.all.map(&:chat)
    assert_not_includes seen.flatten, "Private."

    @lume.account.update!(stalled_sweep_enabled: false)
    other_room.messages.create!(role: "assistant", agent: other, content: "Still private.").update_columns(created_at: @now - 1.hour)
    post(@lume, "Another.", at: @now - 1.hour)
    sweeper(decide: ->(**) { flunk "no account opted in" }).call
  end

  test "the room's last message is the snapshot's: an older timestamp inserted later doesn't hide the room" do
    newest = post(@lume, "Newest by time.", at: @now - 1.hour)
    post(@mira, "Inserted later, older timestamp.", at: @now - 2.hours)

    sweeper(decide: ->(**) { { "can_act:1" => 0.1, "can_act:2" => 0.1, "person_holds" => 0.1 } }).call

    assert_equal newest, StalledThreadSweep.sole.message
  end

  test "deleting a swept room or a swept account still works" do
    post(@lume, "Done.", at: @now - 2.hours)
    quiet = ->(**) { { "can_act:1" => 0.1, "can_act:2" => 0.1, "person_holds" => 0.1 } }
    sweeper(decide: quiet).call
    assert_difference(-> { StalledThreadSweep.count }, -1) { @chat.destroy! }

    other = agents(:other_account_agent)
    other.account.update!(stalled_sweep_enabled: true)
    swept = room(other, "Swept", quiet_since: @now - 2.hours)
    sweeper(decide: ->(**) { { "can_act:1" => 0.1, "person_holds" => 0.1 } }).call
    assert StalledThreadSweep.exists?(chat: swept)
    swept.messages.first.destroy!
    assert_not StalledThreadSweep.exists?(chat: swept)
    other.account.destroy!
    assert_not Chat.exists?(swept.id)
  end

  test "a person's hold and an inference failure are both recorded" do
    post(@lume, "Dana, archived items too, or only active ones?", at: @now - 2.hours)
    sweeper(decide: ->(**) { { "can_act:1" => 0.2, "can_act:2" => 0.1, "person_holds" => 0.9 } }).call
    assert_equal "person_holds", StalledThreadSweep.sole.outcome

    other = room(@lume, "Other", quiet_since: @now - 2.hours)
    sweeper(decide: ->(**) { raise UtilityInference::InvalidResponse, "nope" }).call
    error = StalledThreadSweep.find_by!(chat: other)
    assert_equal [ "error", "UtilityInference::InvalidResponse" ], [ error.outcome, error.error_class ]
  end

  test "the interval setting accepts only the offered values" do
    setting = Setting.instance
    assert setting.update(stalled_sweep_minutes: 30)
    assert_equal 30.minutes, StalledThreadSweeper.interval
    assert_not setting.update(stalled_sweep_minutes: 7)
    setting.reload.update!(stalled_sweep_minutes: 0)
    assert_nil StalledThreadSweeper.interval
  end

  private

  def sweeper(interval: 30.minutes, decide:)
    StalledThreadSweeper.new(now: @now, interval: interval, decide: decide)
  end

  def room(agent, title, quiet_since:)
    chat = agent.account.chats.create!(title: title, manual_responses: true, agents: [ agent ])
    chat.chat_agents.update_all(created_at: 1.day.ago)
    chat.messages.create!(role: "assistant", agent: agent, content: "#{title}: last word.").update_columns(created_at: quiet_since)
    chat
  end

  def post(author, content, at:)
    attributes = author.is_a?(Agent) ? { role: "assistant", agent: author } : { role: "user", user: author }
    message = @chat.messages.create!(content: content, **attributes)
    message.update_columns(created_at: at, updated_at: at)
    message
  end

end
