require "test_helper"

# A claimed run can wait in master's admission queue long after its ten-minute
# claim. Admission is therefore the last check that its dispatch still stands
# (#97 integration, Mira's third boundary).
class ResidentTurnDispatchAuthorityTest < ActiveSupport::TestCase

  setup do
    @previous_async = ENV["SOULSHOUSE_ASYNC_TURNS"]
    ENV["SOULSHOUSE_ASYNC_TURNS"] = "1"
    @user = users(:user_1)
    @account = accounts(:team_account)
    @resident = @account.agents.create!(name: "Solo", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.new(model_id: "openrouter/auto", title: "Queue", manual_responses: true)
    @chat.agent_ids = [ @resident.id ]
    @chat.save!
    Setting.instance.update!(resident_turn_limit: 0) # saturated: nothing is admitted yet
  end

  teardown do
    ENV["SOULSHOUSE_ASYNC_TURNS"] = @previous_async
  end

  test "an unchanged claimed turn is admitted once capacity frees" do
    turn = queued_claimed_turn
    Setting.instance.update!(resident_turn_limit: 1)

    assert_equal [ turn.id ], ResidentTurn.admit!
    assert_equal "starting", turn.reload.state
  end

  test "past the six-hour boundary a queued turn never enters the runtime" do
    turn = queued_claimed_turn

    travel MessageDispatch::RECOVERY_HORIZON + 1.minute do
      Setting.instance.update!(resident_turn_limit: 1)
      assert_empty ResidentTurn.admit!
    end

    assert_equal "cancelled", turn.reload.state
    assert_equal "cancelled", turn.agent_runtime_interaction.reload.execution_state
    assert @dispatch.reload.settled_at.present?
  end

  test "a discard while queued stops the unsubmitted turn at admission" do
    turn = queued_claimed_turn
    @message.discard_as_author!
    Setting.instance.update!(resident_turn_limit: 1)

    assert_empty ResidentTurn.admit!
    assert_equal "cancelled", turn.reload.state
    assert_equal "cancelled", @dispatch.reload.status
  end

  test "membership loss while queued stops the unsubmitted turn at admission" do
    turn = queued_claimed_turn
    @account.memberships.find_by!(user: @user).update_column(:confirmed_at, nil)
    Setting.instance.update!(resident_turn_limit: 1)

    assert_empty ResidentTurn.admit!
    assert_equal "cancelled", turn.reload.state
    assert_equal "author_not_member", @dispatch.reload.reason
  end

  test "retrying does not extend the ten-minute claim: an unclaimed run past it cannot claim" do
    @message = @chat.messages.create!(role: "user", user: @user, content: "Hello")
    interaction = @message.message_dispatch.runtime_interaction

    travel MessageDispatch::EXPIRY + 1.minute do
      assert_not interaction.reload.claim_dispatch!
      assert_equal 0, ResidentTurn.count
    end
  end

  private

  # A human message's automatic wake, claimed, and queued behind admission.
  def queued_claimed_turn
    @message = @chat.messages.create!(role: "user", user: @user, content: "Hello")
    @dispatch = @message.message_dispatch
    assert_equal "reserved", @dispatch.status
    interaction = @dispatch.runtime_interaction
    assert interaction.claim_dispatch!
    turn = ResidentTurn.enqueue!(interaction, { session_id: interaction.session_id, request: "prompt" })
    assert_nil interaction.reload.execution_deadline_at
    turn
  end

end
