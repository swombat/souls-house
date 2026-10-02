require "test_helper"

class ReplyExpectationTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @chat = accounts(:personal_account).chats.create!(title: "Reply attention")
    @ask = @chat.messages.create!(role: "assistant", content: "Test User, which date works?")
  end

  test "one inference per message and person and no manual record required" do
    2.times { record(@ask) }
    assert_equal 1, ReplyExpectation.where(message: @ask, user: @user).count
    assert record(@ask).state_open?
  end

  test "any later human reply closes the expectation mechanically" do
    expectation = record(@ask)
    reply = @chat.messages.create!(role: "user", user: @user, content: "I'll look tonight")
    assert expectation.reload.state_answered?
    assert_equal reply, expectation.answered_by_message
  end

  test "late classification and reclassification after edit cannot reopen a replied message" do
    reply = @chat.messages.create!(role: "user", user: @user, content: "Tuesday")
    assert record(@ask).state_answered?
    @ask.update!(content: "Test User, which date do you prefer?")
    assert_equal reply, record(@ask).answered_by_message
    assert record(@ask).state_answered?
  end

  test "dismissal before inference is sticky but newer asks survive" do
    ReplyDismissal.dismiss!(chat: @chat, user: @user, through: @ask)
    assert record(@ask).state_dismissed?
    @ask.update!(content: "Test User, is Tuesday good?")
    assert record(@ask).state_dismissed?
    newer = @chat.messages.create!(role: "assistant", content: "And Test User, which place?")
    assert record(newer).state_open?
  end

  test "older dismissal cannot move cutoff backwards or clear a newer ask" do
    newer = @chat.messages.create!(role: "assistant", content: "Another ask")
    record(newer)
    ReplyDismissal.dismiss!(chat: @chat, user: @user, through: @ask)
    assert record(newer).state_open?
    ReplyDismissal.dismiss!(chat: @chat, user: @user, through: newer)
    ReplyDismissal.dismiss!(chat: @chat, user: @user, through: @ask)
    assert_equal newer.id, ReplyDismissal.find_by!(chat: @chat, user: @user).through_message_id
  end

  test "summary counts threads across confirmed accounts and scopes thread counts to current account" do
    other_chat = accounts(:team_account).chats.create!(title: "Another account")
    other_ask = other_chat.messages.create!(role: "assistant", content: "Test User, please reply")
    record(@ask)
    record(other_ask)
    summary = ReplyExpectation.summary_for(@user, account: @chat.account)
    assert_equal({ @chat.to_param => @ask.to_param }, summary[:through_messages])
    assert_equal 2, summary[:total]
    assert_equal({ @chat.to_param => 1 }, summary[:chats])
    assert_equal 1, summary[:accounts][other_chat.account.to_param]
    assert_equal 0, ReplyExpectation.summary_for(users(:existing_user), account: @chat.account)[:total]
  end

  test "account and total badges count distinct threads rather than repeated requests" do
    record(@ask)
    3.times do |i|
      record(@chat.messages.create!(role: "assistant", content: "Another request #{i}"))
    end
    assert_equal 1, summary[:total]
    assert_equal 1, summary[:accounts][@chat.account.to_param]
    assert_equal 4, summary[:chats][@chat.to_param]
    assert_equal @chat.messages.order(:id).last.to_param, summary[:through_messages][@chat.to_param]

    second_chat = @chat.account.chats.create!(title: "Second thread")
    record(second_chat.messages.create!(role: "assistant", content: "Another thread"))
    other_chat = accounts(:team_account).chats.create!(title: "Other account")
    2.times { |i| record(other_chat.messages.create!(role: "assistant", content: "Other request #{i}")) }
    assert_equal 3, summary[:total]
    assert_equal({ @chat.account.to_param => 2, other_chat.account.to_param => 1 }, summary[:accounts])
    assert_equal({ @chat.to_param => 4, second_chat.to_param => 1 }, summary[:chats])

    ReplyDismissal.dismiss!(chat: @chat, user: @user, through: @chat.messages.order(:id).last)
    assert_equal 2, summary[:total]
    assert_equal 1, summary[:accounts][@chat.account.to_param]
    second_chat.messages.create!(role: "user", user: @user, content: "Replied")
    assert_equal 1, summary[:total]
    assert_not summary[:accounts].key?(@chat.account.to_param)
  end

  test "access revocation and source discard remove counts including for site admin" do
    record(@ask)
    @ask.discard!
    assert_equal 0, summary[:total]
    @ask.undiscard!
    assert_equal 1, summary[:total]
    @chat.discard!
    assert_equal 0, summary[:total]
    @chat.undiscard!
    @user.update!(is_site_admin: true)
    Membership.find_by!(account: @chat.account, user: @user).update_column(:confirmed_at, nil)
    assert_equal 0, summary[:total]
    assert_nil record(@ask)
  end

  test "disabled account does not appear" do
    record(@ask)
    @chat.account.update!(disabled_at: Time.current)
    assert_equal 0, summary[:total]
  end

  test "tool streaming progress and metadata updates do not queue inference" do
    clear_enqueued_jobs
    @chat.messages.create!(role: "tool", content: "Test User?")
    @chat.messages.create!(role: "assistant", content: "Test User, streaming?", streaming: true)
    @chat.messages.create!(role: "assistant", content: "Test User, progress?", progress_message: true)
    @ask.update!(input_tokens: 100)
    assert_enqueued_jobs 0, only: ClassifyReplyExpectationsJob
    @ask.update!(content: "Test User, can you choose?")
    assert_enqueued_jobs 1, only: ClassifyReplyExpectationsJob
  end

  test "classifier enqueue failure does not turn a committed message into a failed send" do
    ClassifyReplyExpectationsJob.stub :set, ->(**) { raise "synthetic queue outage" } do
      message = @chat.messages.create!(role: "assistant", content: "Another question")
      assert message.persisted?
      assert message.reply_attention_pending?
    end
  end

  private

  def record(message)
    message.chat.with_lock { ReplyExpectation.record!(message: message, user: @user, score: 0.95) }
  end

  def summary
    ReplyExpectation.summary_for(@user, account: @chat.account)
  end

end
