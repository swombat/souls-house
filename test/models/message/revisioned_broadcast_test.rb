require "test_helper"

# Step 5 of #94 B: every revision taken is announced on the chat's app stream
# after commit, as a bare invalidation.
class Message::RevisionedBroadcastTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @user = User.create!(email_address: "revb#{SecureRandom.hex(4)}@example.com", password: "password123")
    @chat = Chat.create!(account: @user.personal_account)
    @stream = Message::Revisioned.stream_name(@chat.id)
  end

  test "a create announces the revision it took, and nothing else" do
    @chat.messages.create!(user: @user, role: "user", content: "a secret")

    assert_broadcast_on(@stream, changed(1))
    assert_equal [ changed(1).stringify_keys ], broadcasts(@stream).map { |raw| JSON.parse(raw) }
  end

  test "edit, discard and restore each announce their revision" do
    message = @chat.messages.create!(user: @user, role: "user", content: "one")
    message.update!(content: "edited")
    message.discard!
    message.undiscard!

    assert_equal [ 1, 2, 3, 4 ], broadcasts(@stream).map { |raw| JSON.parse(raw)["latest_revision"] }
  end

  test "a resident reply announces like a human message" do
    @chat.messages.create!(role: "assistant", content: "reply")

    assert_broadcast_on(@stream, changed(1))
  end

  test "bookkeeping and streaming chunks announce nothing; finishing the stream does" do
    message = @chat.messages.create!(role: "assistant", content: "")
    message.update!(input_tokens: 10)
    message.update_columns(streaming: true, content: "partial")
    assert_broadcasts @stream, 1

    message.update!(streaming: false, content: "partial and done")
    assert_broadcasts @stream, 2
    assert_broadcast_on(@stream, changed(2))
  end

  test "the progress seam written with update_columns still announces" do
    previous = @chat.messages.create!(role: "assistant", content: "one")
    previous.update_columns_with_revision(progress_break_after: true)

    assert_broadcast_on(@stream, changed(2))
  end

  test "nothing is announced before the outermost commit, and nothing on rollback" do
    Message.transaction do
      @chat.messages.create!(user: @user, role: "user", content: "pending")
      Message.transaction(requires_new: true) do
        @chat.messages.create!(user: @user, role: "user", content: "inner")
      end
      assert_no_broadcasts @stream
    end
    assert_equal [ 1, 2 ], broadcasts(@stream).map { |raw| JSON.parse(raw)["latest_revision"] }

    Message.transaction do
      @chat.messages.create!(user: @user, role: "user", content: "doomed")
      raise ActiveRecord::Rollback
    end
    assert_broadcasts @stream, 2
  end

  test "each chat announces on its own stream" do
    other = Chat.create!(account: @user.personal_account)
    other.messages.create!(user: @user, role: "user", content: "there")

    assert_no_broadcasts @stream
    assert_broadcasts Message::Revisioned.stream_name(other.id), 1
  end

  test "a failed broadcast doesn't fail the committed write" do
    server = ActionCable.server
    original = server.method(:broadcast)
    failing = ->(stream, *rest, **opts) { stream == @stream ? raise("cable down") : original.call(stream, *rest, **opts) }
    server.stub(:broadcast, failing) do
      @chat.messages.create!(user: @user, role: "user", content: "still saved")
    end

    assert_equal 1, @chat.reload.message_revision
  end

  private

  def changed(revision)
    { type: "changed", conversation_id: @chat.to_param, latest_revision: revision }
  end

end
