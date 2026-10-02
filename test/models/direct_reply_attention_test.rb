require "test_helper"

class DirectReplyAttentionTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @user.profile.update!(first_name: "Daniel", last_name: "Tenner")
    @chat = accounts(:personal_account).chats.create!(title: "Direct tags")
  end

  test "resident and human direct tags create attention during the save without inference" do
    UtilityInference.stub :decide, ->(**) { flunk "Tags must not call a provider" } do
      [ { role: "assistant", agent: agents(:research_assistant) },
        { role: "user", user: users(:existing_user) } ].each_with_index do |author, index|
        message = @chat.messages.create!(**author, content: "@Daniel — tagging you, as asked. #{index}")
        expectation = ReplyExpectation.find_by!(message: message, user: @user)
        assert expectation.state_open?
        assert_equal ReplyExpectation::DIRECT_MENTION_VERSION, expectation.classifier_version
        assert_equal 1.0, expectation.score
      end
    end
    assert_equal 1, ReplyExpectation.summary_for(@user, account: @chat.account)[:total]
  end

  test "a model negative or abstention cannot erase a direct tag" do
    message = tag
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.01 } } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert ReplyExpectation.find_by!(message: message).state_open?
    message.update!(content: "@Daniel still deliberately tagged")
    UtilityInference.stub :decide, ->(state:, questions:) { questions.transform_values { 0.99 } } do
      ReplyRecipientResolver.stub :call, ->(state:, message_ids:) { message_ids.index_with { nil } } do
        ClassifyReplyExpectationsJob.perform_now(@chat.id)
      end
    end
    assert ReplyExpectation.find_by!(message: message).state_open?
    assert_not message.reload.reply_attention_pending?
  end

  test "provider and queue failures do not prevent direct attention" do
    message = nil
    ClassifyReplyExpectationsJob.stub :set, ->(**) { raise "synthetic queue outage" } do
      message = tag
    end
    UtilityInference.stub :decide, ->(**) { raise UtilityInference::InvalidResponse, "unavailable" } do
      ClassifyReplyExpectationsJob.perform_now(@chat.id)
    end
    assert ReplyExpectation.find_by!(message: message).state_open?
  end

  test "removing a tag removes only its open record and retagging cannot reopen dismissals" do
    message = tag
    message.update!(content: "No tag now")
    assert_empty ReplyExpectation.where(message: message)
    message.update!(content: "@Daniel again")
    ReplyDismissal.dismiss!(chat: @chat, user: @user, through: message)
    message.update!(content: "No tag anymore")
    message.update!(content: "@Daniel once more")
    assert ReplyExpectation.find_by!(message: message).state_dismissed?
  end

  test "reply closes tag and later edits do not reopen it" do
    message = tag
    @chat.messages.create!(role: "user", user: @user, content: "Seen")
    message.update!(content: "@Daniel edited")
    assert ReplyExpectation.find_by!(message: message).state_answered?
  end

  test "self tags unconfirmed members and disabled accounts do not open attention" do
    @chat.messages.create!(role: "user", user: @user, content: "@Daniel myself")
    assert_empty ReplyExpectation.all
    membership = Membership.find_by!(account: @chat.account, user: @user)
    membership.update_column(:confirmed_at, nil)
    tag
    assert_empty ReplyExpectation.all
    membership.update_column(:confirmed_at, Time.current)
    @chat.account.update!(disabled_at: Time.current)
    tag("@Daniel disabled")
    assert_empty ReplyExpectation.all
  end

  test "streaming tool and progress messages wait or never tag" do
    message = @chat.messages.create!(role: "assistant", content: "@Daniel streaming", streaming: true)
    @chat.messages.create!(role: "tool", content: "@Daniel tool")
    @chat.messages.create!(role: "assistant", content: "@Daniel progress", progress_message: true)
    assert_empty ReplyExpectation.all
    message.update!(streaming: false)
    assert ReplyExpectation.find_by!(message: message).state_open?
  end

  test "progress-only transitions reconcile tags and cannot be undone by a job" do
    message = @chat.messages.create!(role: "assistant", content: "@Daniel progress", progress_message: true)
    message.update!(progress_message: false)
    assert ReplyExpectation.find_by!(message: message).state_open?
    UtilityInference.stub :decide, ->(state:, questions:) {
      message.update!(progress_message: true)
      questions.transform_values { 0.99 }
    } do
      ReplyRecipientResolver.stub :call, ->(state:, message_ids:) { message_ids.index_with { [ "user:#{@user.id}" ] } } do
        ClassifyReplyExpectationsJob.perform_now(@chat.id)
      end
    end
    ClassifyReplyExpectationsJob.perform_now(@chat.id)
    assert_empty ReplyExpectation.where(message: message)
  end

  test "clearing assistant content removes the open tag" do
    message = tag
    message.update!(content: "")
    assert_empty ReplyExpectation.where(message: message)
  end

  test "rollback rolls back the tag along with the message" do
    Message.transaction do
      tag
      raise ActiveRecord::Rollback
    end
    assert_empty ReplyExpectation.all
  end

  private

  def tag(content = "@Daniel — tagging you, as asked.")
    @chat.messages.create!(role: "assistant", content: content)
  end

end
