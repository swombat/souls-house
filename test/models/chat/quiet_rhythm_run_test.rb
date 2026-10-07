require "test_helper"

class Chat::QuietRhythmRunTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @other_agent = agents(:code_reviewer)
    @account = @agent.account
    @now = Time.utc(2026, 10, 7, 10)
  end

  test "a resident's solo rhythm run is quiet and off the list" do
    chat = fire(resident_rhythm)
    assert chat.quiet_rhythm_run?
    assert_includes Chat.quiet_rhythm_runs, chat
    assert_not_includes @account.chats.listed, chat
  end

  test "a person's solo rhythm is quiet too: its own opening message does not count as a person posting" do
    chat = fire(person_rhythm)
    assert_equal "user", chat.messages.first.role
    assert chat.quiet_rhythm_run?
  end

  test "the resident's own replies keep the run quiet" do
    chat = fire(resident_rhythm)
    chat.messages.create!(role: "assistant", agent: @agent, content: "Nothing changed today.", suppress_automatic_dispatch: true)
    assert chat.quiet_rhythm_run?
  end

  test "a person replying brings the run into the list" do
    chat = fire(resident_rhythm)
    chat.messages.create!(role: "user", user: @user, content: "Thanks, noted.", suppress_automatic_dispatch: true)
    assert_not chat.quiet_rhythm_run?
    assert_includes @account.chats.listed, chat
  end

  test "a deleted human reply does not count" do
    chat = fire(resident_rhythm)
    reply = chat.messages.create!(role: "user", user: @user, content: "Oops", suppress_automatic_dispatch: true)
    reply.discard!
    assert chat.quiet_rhythm_run?
  end

  test "the eye on any message brings the run in, and dismissing it does not hide the run again" do
    chat = fire(resident_rhythm)
    message = chat.messages.create!(role: "assistant", agent: @agent, content: "Daniel, can you look at this?",
      suppress_automatic_dispatch: true)
    expectation = ReplyExpectation.record!(message: message, user: @user, score: 0.9, classifier_version: "test")
    assert_not chat.quiet_rhythm_run?
    expectation.update!(state: :dismissed)
    assert_not chat.quiet_rhythm_run?
  end

  test "the eye touches the run so the sidebar refreshes" do
    chat = fire(resident_rhythm)
    message = chat.messages.create!(role: "assistant", agent: @agent, content: "Daniel?", suppress_automatic_dispatch: true)
    before = chat.reload.updated_at
    travel 1.minute do
      ReplyExpectation.record!(message: message, user: @user, score: 0.9, classifier_version: "test")
    end
    assert_operator chat.reload.updated_at, :>, before
  end

  test "a second resident taking a seat brings the run in" do
    chat = fire(resident_rhythm)
    before = chat.reload.updated_at
    travel 1.minute do
      chat.chat_agents.create!(agent: @other_agent)
    end
    assert_not chat.quiet_rhythm_run?
    assert_operator chat.reload.updated_at, :>, before
  end

  test "a rhythm with two residents is never quiet" do
    rhythm = resident_rhythm
    rhythm.update!(agents: [ @agent, @other_agent ])
    chat = fire(rhythm)
    assert_not chat.quiet_rhythm_run?
  end

  test "an ordinary conversation is never quiet" do
    chat = @account.chats.create_with_message!({ title: "Plain", manual_responses: true },
      message_content: nil, agent_ids: [ @agent.id ], automatic_response: false)
    assert_not chat.quiet_rhythm_run?
    assert_includes @account.chats.listed, chat
  end

  test "deleting the rhythm brings its runs back to the list" do
    rhythm = resident_rhythm
    chat = fire(rhythm)
    rhythm.destroy!
    assert_not chat.reload.quiet_rhythm_run?
  end

  private

  def resident_rhythm
    Rhythm.create!(account: @account, creator_agent: @agent, title: "House watch", opening: "Look round the house.",
      agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC", next_run_at: @now - 1.hour)
  end

  def person_rhythm
    Rhythm.create!(account: @account, creator: @user, title: "Morning look", opening: "What is taking shape?",
      agents: [ @agent ], cadence: "daily", time_of_day: "09:00", timezone: "UTC", next_run_at: @now - 1.hour)
  end

  def fire(rhythm)
    result = rhythm.fire!(now: @now)
    assert_equal :created, result.status, result.reason
    result.occurrence.chat.reload
  end

end
