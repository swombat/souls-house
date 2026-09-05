require "test_helper"
class ModerateMessageJobTest < ActiveJob::TestCase

  setup do
    @user = User.create!(
      email_address: "test#{SecureRandom.hex(4)}@example.com",
      password: "password123"
    )
    @user.profile.update!(first_name: "Test", last_name: "User")
    @account = @user.personal_account
    @chat = Chat.create!(account: @account)
    @message = @chat.messages.create!(
      role: "assistant",
      content: "Test content"
    )
    @message.update_columns(moderated_at: nil, moderation_scores: nil)
  end

  test "moderates through utility inference and updates message scores" do
    UtilityInference.stub :moderate, { "hate" => 0.01 } do
      ModerateMessageJob.perform_now(@message)
    end

    @message.reload
    assert_kind_of Hash, @message.moderation_scores
    assert @message.moderation_scores.key?("hate")
    assert_not_nil @message.moderated_at
  end

  test "skips messages with blank content" do
    @message.update_columns(content: "")

    ModerateMessageJob.perform_now(@message)

    assert_nil @message.reload.moderated_at
  end

  test "skips already moderated messages" do
    @message.update_columns(moderated_at: 1.hour.ago)
    original_moderated_at = @message.moderated_at

    ModerateMessageJob.perform_now(@message)

    # Verify moderated_at was not changed
    assert_equal original_moderated_at, @message.reload.moderated_at
  end

  test "is discarded when message record not found" do
    message_id = @message.id
    @message.destroy

    # Should not raise ActiveRecord::RecordNotFound
    assert_nothing_raised do
      ModerateMessageJob.perform_now(Message.find_by(id: message_id) || Message.new)
    end
  end

end
