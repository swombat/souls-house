require "test_helper"

class StalledThreadSnapshotTest < ActiveSupport::TestCase

  setup do
    @lume = agents(:research_assistant)
    @mira = agents(:code_reviewer)
    @user = users(:existing_user)
    @chat = @lume.account.chats.create!(title: "Sweeper", manual_responses: true, agents: [ @lume, @mira ])
    @t0 = Time.zone.parse("2026-10-10 10:00:00")
  end

  test "the window is the last three speaker-runs, oldest first, and says what it left out" do
    post(@user, "Please build it", at: @t0)
    post(@lume, "On it", at: @t0 + 1.minute)
    post(@lume, "PR #1 is up, ready for review", at: @t0 + 10.minutes)
    post(@mira, "Reviewing", at: @t0 + 11.minutes)
    post(@mira, "Changes requested", at: @t0 + 12.minutes)
    post(@lume, "Fixed at abc123, over to you", at: @t0 + 20.minutes)

    state = StalledThreadSnapshot.new(@chat, now: @t0 + 2.hours + 20.minutes).state
    assert_equal [ "On it", "PR #1 is up, ready for review", "Reviewing", "Changes requested", "Fixed at abc123, over to you" ],
      state[:window].pluck(:content)
    assert state[:window_truncated]
    assert_equal "Please build it", state[:earlier_human_request][:content]
    assert_equal 120, state[:quiet_for_minutes]
    assert_equal "resident", state[:last_message][:kind]
    assert_not state[:last_human_after_last_resident]
  end

  test "latest_by_participant says who has said nothing since the last message" do
    post(@user, "Go", at: @t0)
    post(@mira, "Approved, merge is yours", at: @t0 + 5.minutes)
    post(@lume, "Thanks, merging once CI is green", at: @t0 + 6.minutes)

    state = StalledThreadSnapshot.new(@chat, now: @t0 + 3.hours).state
    by_name = state[:latest_by_participant].index_by { |e| e[:participant] }
    assert by_name[@mira.name][:others_spoke_since]
    assert_not by_name[@lume.name][:others_spoke_since]
    assert by_name[@user.full_name][:others_spoke_since]
    assert_equal "human", by_name[@user.full_name][:kind]
  end

  test "a historical snapshot sees nothing after as_of" do
    first = post(@lume, "PR is up", at: @t0)
    post(@mira, "Reviewed", at: @t0 + 3.hours)

    state = StalledThreadSnapshot.new(@chat, as_of: first, now: @t0 + 2.hours).state
    assert_equal [ "PR is up" ], state[:window].pluck(:content)
    assert_equal 120, state[:quiet_for_minutes]
  end

  test "long messages keep their head and their tail" do
    body = ("a" * 2_000) + " MERGE IS YOURS"
    post(@mira, body, at: @t0)

    content = StalledThreadSnapshot.new(@chat, now: @t0 + 2.hours).state[:window].first[:content]
    assert_operator content.length, :<, body.length
    assert content.end_with?("MERGE IS YOURS")
    assert content.start_with?("aaaa")
    assert_includes content, "[...]"
  end

  test "progress rows and discarded messages are left out" do
    post(@lume, "Working...", at: @t0, progress: true)
    gone = post(@lume, "Oops", at: @t0 + 1.minute)
    gone.discard
    post(@lume, "Done", at: @t0 + 2.minutes)

    assert_equal [ "Done" ], StalledThreadSnapshot.new(@chat, now: @t0 + 3.hours).state[:window].pluck(:content)
  end

  test "the questions are one per resident plus person_holds, each naming its resident" do
    questions = StalledThreadSweeperQuestions.for(@chat)
    assert_equal [ "person_holds", StalledThreadSweeperQuestions.wake_key(@lume), StalledThreadSweeperQuestions.wake_key(@mira) ].sort,
      questions.keys.sort
    assert_includes questions[StalledThreadSweeperQuestions.wake_key(@mira)][:instructions], @mira.name
    assert_not_includes questions[StalledThreadSweeperQuestions.wake_key(@mira)][:instructions], "\n"
    assert questions.values.all? { |q| q[:type] == "noul" }
  end

  private

  def post(author, content, at:, progress: false)
    attributes = { content: content, created_at: at, updated_at: at, progress_message: progress }
    if author.is_a?(Agent)
      @chat.messages.create!(attributes.merge(role: "assistant", agent: author))
    else
      @chat.messages.create!(attributes.merge(role: "user", user: author))
    end
  end

end
