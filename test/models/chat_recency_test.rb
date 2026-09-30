require "test_helper"

class ChatRecencyTest < ActiveSupport::TestCase

  setup do
    @account = accounts(:personal_account)
    @older = @account.chats.create!(title: "Older", created_at: 3.days.ago)
    @newer = @account.chats.create!(title: "Newer", created_at: 2.days.ago)
  end

  test "renaming and metadata changes do not bump a chat" do
    @older.update!(title: "Renamed", context_tokens: 123)
    assert_equal [ @newer.id, @older.id ], ordered_ids
    assert_equal @older.created_at, @older.activity_at
    assert_equal @older.activity_at.as_json, @older.as_json(as: :sidebar_json)["activity_at"].as_json
  end

  test "new messages bump a chat but edits and streaming updates do not" do
    message = @older.messages.create!(role: "assistant", content: "First", created_at: 1.day.ago)
    assert_equal [ @older.id, @newer.id ], ordered_ids
    @newer.messages.create!(role: "assistant", content: "Second", created_at: 1.hour.ago)
    message.update!(content: "Edited", streaming: false)
    @older.reload
    assert_equal message.created_at, @older.last_message_at
    assert_equal [ @newer.id, @older.id ], ordered_ids
  end

  test "backdated messages cannot move the activity clock backwards" do
    recent = @older.messages.create!(role: "assistant", content: "Recent")
    @older.messages.create!(role: "assistant", content: "Imported", created_at: 5.days.ago)
    assert_equal recent.created_at, @older.reload.last_message_at
  end

  private

  def ordered_ids
    @account.chats.where(id: [ @older.id, @newer.id ]).latest.pluck(:id)
  end

end
