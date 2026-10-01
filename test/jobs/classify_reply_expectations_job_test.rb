require "test_helper"

class ClassifyReplyExpectationsJobTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @chat = accounts(:personal_account).chats.create!(title: "Attention")
    @ask = @chat.messages.create!(role: "assistant", content: "Test User, please choose")
  end

  test "bursts share one call and duplicate jobs do no work" do
    second = @chat.messages.create!(role: "assistant", content: "Also Test User, which date?")
    calls = 0
    UtilityInference.stub :decide, ->(state:, questions:) {
      calls += 1
      assert_equal [ @ask.id, second.id ], state[:messages].pluck(:id)
      questions.transform_values { 0.95 }
    } do
      2.times { ClassifyReplyExpectationsJob.perform_now(@chat.id) }
    end
    assert_equal 1, calls
    assert_equal 2, ReplyExpectation.state_open.count
  end

  test "a reply or dismissal arriving during inference wins over its result" do
    UtilityInference.stub :decide, ->(state:, questions:) {
      ReplyDismissal.dismiss!(chat: @chat, user: @user, through: @ask)
      questions.transform_values { 0.95 }
    } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert ReplyExpectation.find_by!(message: @ask).state_dismissed?
  end

  test "recipient reply during inference creates answered not open" do
    UtilityInference.stub :decide, ->(state:, questions:) {
      @chat.messages.create!(role: "user", user: @user, content: "Later")
      questions.transform_values { 0.95 }
    } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert ReplyExpectation.find_by!(message: @ask).state_answered?
  end

  test "stale edited source does not accept result" do
    UtilityInference.stub :decide, ->(state:, questions:) {
      @ask.update!(content: "No need to reply")
      questions.transform_values { 0.95 }
    } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert_empty ReplyExpectation.where(message: @ask)
    assert @ask.reload.reply_attention_pending?
  end

  test "revocation during inference prevents creating a row" do
    UtilityInference.stub :decide, ->(state:, questions:) {
      Membership.find_by!(account: @chat.account, user: @user).update_column(:confirmed_at, nil)
      questions.transform_values { 0.95 }
    } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert_empty ReplyExpectation.where(message: @ask)
  end

  test "negative edit removes only open inference and provider errors do not clear it" do
    @chat.with_lock { ReplyExpectation.record!(message: @ask, user: @user, score: 0.95) }
    UtilityInference.stub :decide, ->(**) { raise UtilityInference::InvalidResponse, "unavailable" } do
      assert_enqueued_with(job: ClassifyReplyExpectationsJob) { ClassifyReplyExpectationsJob.perform_now(@chat.id) }
    end
    assert_equal 1, ReplyExpectation.state_open.count
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.1 } } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert_empty ReplyExpectation.where(message: @ask)
  end

  test "pre-existing messages are not swept" do
    @ask.update_column(:reply_attention_pending, false)
    UtilityInference.stub :decide, ->(**) { flunk "No historical classification" } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert_empty ReplyExpectation.where(message: @ask)
  end

  test "an oversized message neither starves a smaller ask nor endlessly reschedules" do
    smaller = @chat.messages.create!(role: "assistant", content: "A small new ask")
    UtilityInference.stub :decide, ->(state:, questions:) {
      raise UtilityInference::InputTooLong if state[:messages].any? { |m| m[:id] == @ask.id }
      questions.transform_values { 0.95 }
    } do
      clear_enqueued_jobs
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
      assert_enqueued_jobs 0, only: ClassifyReplyExpectationsJob
    end
    assert_not @ask.reload.reply_attention_pending?
    assert_not smaller.reload.reply_attention_pending?
    assert ReplyExpectation.find_by!(message: smaller).state_open?
  end

end
