require "test_helper"

class StalledThreadSweeperTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @person = users(:user_1)
    @chat = @lume.account.chats.create!(title: "Quiet room", manual_responses: true, agents: [ @lume, @mira ])
    @chat.chat_agents.update_all(created_at: 1.day.ago)
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

  test "rooms still inside the interval, too old, or with a run going are left alone" do
    post(@lume, "Just said this.", at: @now - 5.minutes)
    old_room = @lume.account.chats.create!(title: "Old", manual_responses: true, agents: [ @lume ])
    old_room.messages.create!(role: "assistant", agent: @lume, content: "Long ago.").update_columns(created_at: @now - 5.days)
    busy_room = @lume.account.chats.create!(title: "Busy", manual_responses: true, agents: [ @lume ])
    busy_room.chat_agents.update_all(created_at: 1.day.ago)
    busy_room.messages.create!(role: "assistant", agent: @lume, content: "Working.").update_columns(created_at: @now - 2.hours)
    AgentRuntimeInteraction.create!(agent: @lume, chat: busy_room, trigger_kind: "conversation", requested_by: "souls.house",
      started_at: 5.minutes.ago, execution_state: "running")

    sweeper(decide: ->(**) { flunk "nothing to judge" }).call

    assert_equal 0, StalledThreadSweep.count
  end

  test "a person's hold and an inference failure are both recorded" do
    post(@lume, "Dana, archived items too, or only active ones?", at: @now - 2.hours)
    sweeper(decide: ->(**) { { "can_act:1" => 0.2, "can_act:2" => 0.1, "person_holds" => 0.9 } }).call
    assert_equal "person_holds", StalledThreadSweep.sole.outcome

    other = @lume.account.chats.create!(title: "Other", manual_responses: true, agents: [ @lume ])
    other.chat_agents.update_all(created_at: 1.day.ago)
    other.messages.create!(role: "assistant", agent: @lume, content: "Hm.").update_columns(created_at: @now - 2.hours)
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

  def post(author, content, at:)
    attributes = author.is_a?(Agent) ? { role: "assistant", agent: author } : { role: "user", user: author }
    message = @chat.messages.create!(content: content, **attributes)
    message.update_columns(created_at: at, updated_at: at)
    message
  end

end
