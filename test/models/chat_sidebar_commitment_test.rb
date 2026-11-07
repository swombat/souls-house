require "test_helper"
require "action_cable/test_helper"

# The sidebar marks a conversation with a resident commitment waiting in it
# (Daniel, 7 Nov, JdwZaj JnwgVy).
class ChatSidebarCommitmentTest < ActiveSupport::TestCase

  include ActionCable::TestHelper

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @lume = @account.agents.create!(name: "Lume", system_prompt: "Test", runtime: "external")
    @mira = @account.agents.create!(name: "Mira", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(title: "Parked thread", manual_responses: true)
    @chat.agents = [ @lume, @mira ]
    @chat.save!
    @other = @account.chats.new(title: "Quiet thread", manual_responses: true)
    @other.agents = [ @lume ]
    @other.save!
    @now = Time.current.change(usec: 0)
  end

  test "a scheduled commitment marks its conversation with the earliest one and the count" do
    assert_nil sidebar(@chat)["next_commitment"]
    commit(@mira, "Check the receipt", at: @now + 3.hours)
    commit(@lume, "Pick S2b back up", at: @now + 1.hour)

    mark = sidebar(@chat)["next_commitment"]
    assert_equal (@now + 1.hour).iso8601, mark["due_at"]
    assert_equal "Lume", mark["resident_name"]
    assert_equal 2, mark["count"]
    assert_nil sidebar(@other)["next_commitment"]
  end

  test "the mark is not cached with the chat and does not touch it" do
    original_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    timestamp = @chat.updated_at
    assert_nil sidebar(@chat)["next_commitment"]
    commitment = commit(@lume, "Come back", at: @now + 1.hour)
    assert_equal 1, sidebar(@chat)["next_commitment"]["count"]
    commitment.cancel!(by: @user)
    assert_nil sidebar(@chat)["next_commitment"]
    assert_equal timestamp, @chat.reload.updated_at
  ensure
    Rails.cache = original_cache
  end

  test "delivered and cancelled commitments leave no mark" do
    delivered = commit(@lume, "Delivered one", at: @now + 1.hour)
    delivered.update!(status: "activated", activated_at: @now, wake_state: "delivered", delivered_at: @now)
    cancelled = commit(@mira, "Cancelled one", at: @now + 1.hour)
    cancelled.cancel!(by: @user)
    assert_nil sidebar(@chat)["next_commitment"]
  end

  test "a commitment that opens a new conversation does not mark the one it was made in" do
    commit(@lume, "Start a fresh thread", at: @now + 1.hour, destination: "new_conversation")
    assert_nil sidebar(@chat)["next_commitment"]
  end

  test "making, moving and cancelling a commitment refresh the account's chat list" do
    channel = "Account:#{@account.obfuscated_id}"
    marker = { action: "refresh", prop: "chats" }
    commitment = nil
    assert_broadcast_on(channel, marker) { commitment = commit(@lume, "Come back", at: @now + 1.hour) }
    assert_broadcast_on(channel, marker) { commitment.reschedule!(due_at: @now + 2.hours) }
    assert_broadcast_on(channel, marker) { commitment.cancel!(by: @user) }
  end

  test "the list costs one commitment query however many conversations it shows" do
    chats = 5.times.map do |i|
      chat = @account.chats.new(title: "Thread #{i}", manual_responses: true)
      chat.agents = [ @lume ]
      chat.save!
      commit(@lume, "Back to #{i}", at: @now + (i + 1).hours, chat: chat)
      chat
    end
    queries = []
    callback = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("commitments") }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { Chat.sidebar_json_for(chats) }
    assert_equal 1, queries.size
  end

  private

  def commit(agent, text, at:, chat: @chat, **attrs)
    Commitment.create!(agent: agent, source_chat: chat, text: text, due_at: at, **attrs)
  end

  def sidebar(chat)
    Chat.sidebar_json_for([ chat ]).first
  end

end
