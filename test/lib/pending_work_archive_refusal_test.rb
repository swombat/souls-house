require "test_helper"

class PendingWorkArchiveRefusalTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @user = users(:confirmed_user)
    @chat = new_chat
  end

  test "returns nil when nothing is owed" do
    assert_nil refusal
  end

  test "lists every open expectation on kept messages without changing them" do
    first = expectation(@chat, @user)
    second_user = users(:other_member)
    second = expectation(@chat, second_user)

    result = refusal

    assert_equal "This conversation still has something owed in it; archiving would dismiss or silence it. Answer, dismiss or cancel these first.", result[:error]
    assert_equal "conversation_has_pending_work", result[:code]
    assert_equal [
      { message_id: first.message.to_param, awaiting: @user.display_name },
      { message_id: second.message.to_param, awaiting: second_user.display_name }
    ].sort_by { _1[:message_id] }, result[:open_reply_expectations].sort_by { _1[:message_id] }
    assert_empty result[:scheduled_commitments]
    assert first.reload.state_open?
    assert second.reload.state_open?
    assert_not @chat.reload.archived?
  end

  test "excludes discarded messages, closed expectations and other conversations" do
    discarded = expectation(@chat, @user)
    discarded.message.update_columns(discarded_at: Time.current)
    expectation(@chat, @user).update!(state: :answered)
    expectation(@chat, @user).update!(state: :dismissed)
    expectation(new_chat, @user)

    assert_nil refusal
    assert discarded.reload.state_open?
  end

  test "includes guest commitments by headline only, ordered by due time" do
    guest = agents(:other_account_agent)
    GuestMembership.create!(account: @chat.account, agent: guest, added_by: @chat.account.owner)
    @chat.agents << guest
    assert_not_equal @chat.account_id, guest.account_id
    later = commitment(@chat, @agent, due_at: 2.hours.from_now)
    earlier = commitment(@chat, guest, due_at: 1.hour.from_now)
    commitment(new_chat, @agent)

    result = refusal

    assert_equal [ earlier, later ].map { |c|
      { id: c.to_param, resident: c.agent.name, due_at: c.due_at.iso8601, status: "scheduled", headline: c.summary }
    }, result[:scheduled_commitments]
    assert_empty result[:open_reply_expectations]
    assert_not_includes result.to_json, "PRIVATE"
    assert_equal "scheduled", earlier.reload.status
  end

  test "cancelled commitments do not refuse" do
    commitment(@chat, @agent).update!(status: "cancelled", cancelled_at: Time.current)

    assert_nil refusal
  end

  test "includes all wakes in custody in their activation chat even when sourced elsewhere" do
    source = new_chat
    owed = Commitment::IN_CUSTODY.map do |state|
      c = commitment(source, @agent)
      c.update_columns(status: "activated", activation_chat_id: @chat.id, wake_state: state, activated_at: Time.current)
      c
    end

    assert_equal owed.map(&:to_param).sort, refusal[:scheduled_commitments].map { _1[:id] }.sort
  end

  test "excludes delivered blocked and withdrawn wakes and custody in other chats" do
    elsewhere = new_chat
    %w[delivered blocked withdrawn].each do |state|
      c = commitment(elsewhere, @agent)
      c.update_columns(status: "activated", activation_chat_id: @chat.id, wake_state: state)
    end
    c = commitment(@chat, @agent)
    c.update_columns(status: "activated", activation_chat_id: elsewhere.id, wake_state: "held")

    assert_nil refusal
  end

  private

  def refusal
    @chat.with_lock { PendingWorkArchiveRefusal.new(@chat).call }
  end

  def new_chat
    @agent.account.chats.create!(title: "Archive guard", manual_responses: true, agents: [ @agent ], model_id: "openrouter/auto")
  end

  def expectation(chat, user)
    message = chat.messages.create!(role: "assistant", agent: @agent, content: "Can you check this? #{SecureRandom.hex(8)}", suppress_automatic_dispatch: true)
    ReplyExpectation.create!(message: message, user: user, score: 0.9, classifier_version: "test")
  end

  def commitment(chat, agent, due_at: 1.hour.from_now)
    Commitment.create!(agent: agent, source_chat: chat, summary: "Check receipt",
      text: "PRIVATE brief #{SecureRandom.hex(8)}", due_at: due_at)
  end

end
