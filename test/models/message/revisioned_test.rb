require "test_helper"

class Message::RevisionedTest < ActiveSupport::TestCase

  setup do
    @user = User.create!(email_address: "rev#{SecureRandom.hex(4)}@example.com", password: "password123")
    @chat = Chat.create!(account: @user.personal_account)
  end

  test "each create takes the chat's next revision" do
    first = @chat.messages.create!(user: @user, role: "user", content: "one")
    second = @chat.messages.create!(user: @user, role: "user", content: "two")
    assert_equal [ 1, 2 ], [ first.revision, second.revision ]
    assert_equal 2, @chat.reload.message_revision
  end

  test "edit, discard and restore each take a new revision" do
    message = @chat.messages.create!(user: @user, role: "user", content: "one")
    revisions = [ message.revision ]
    message.update!(content: "edited")
    revisions << message.revision
    message.discard!
    revisions << message.revision
    message.undiscard!
    revisions << message.revision
    assert_equal [ 1, 2, 3, 4 ], revisions
    assert_equal 4, message.reload.revision
  end

  test "bookkeeping writes don't bump the revision" do
    message = @chat.messages.create!(user: @user, role: "assistant", content: "reply")
    message.update!(input_tokens: 10, output_tokens: 20)
    assert_equal 1, message.reload.revision
    assert_equal 1, @chat.reload.message_revision
  end

  test "streaming chunks don't bump; finishing the stream does" do
    message = @chat.messages.create!(role: "assistant", content: "")
    message.update_columns(streaming: true, content: "partial")
    assert_equal 1, @chat.reload.message_revision
    message.update!(streaming: false, content: "partial and done")
    assert_equal 2, message.reload.revision
  end

  test "revisions are per chat" do
    other = Chat.create!(account: @user.personal_account)
    @chat.messages.create!(user: @user, role: "user", content: "here")
    there = other.messages.create!(user: @user, role: "user", content: "there")
    assert_equal 1, there.revision
  end

  test "a rolled-back write gives its revision back" do
    @chat.messages.create!(user: @user, role: "user", content: "one")
    Message.transaction do
      @chat.messages.create!(user: @user, role: "user", content: "doomed")
      raise ActiveRecord::Rollback
    end
    assert_equal 1, @chat.reload.message_revision
    assert_equal 2, @chat.messages.create!(user: @user, role: "user", content: "two").revision
  end

end
