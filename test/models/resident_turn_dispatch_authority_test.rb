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

# After admission and before the first runtime submission (#97 review round 2).
# The three loss witnesses are Mira's reproducer; the runtime stub also answers
# cancellations, so the withdrawal can be followed to its end.
class ResidentTurnDispatchAuthorityTest

  [ :horizon, :discard, :membership ].each do |loss|
    test "review admitted but never submitted turn rechecks #{loss} before first runtime POST" do
      turn = admitted_turn
      runtime = FakeRuntime.new
      @message.discard_as_author! if loss == :discard
      @account.memberships.find_by!(user: @user).update_column(:confirmed_at, nil) if loss == :membership
      run = -> { poll(turn, runtime) }
      loss == :horizon ? travel(MessageDispatch::RECOVERY_HORIZON + 1.minute, &run) : run.call

      assert_empty runtime.submitted, "admission is not runtime submission; #{loss} must prevent the first POST"
      assert_equal [ turn.dispatch_id ], runtime.cancelled
      assert_equal "cancelled", turn.reload.state
      assert turn.finished_at?
    end
  end

  test "a withdrawn turn keeps its slot until the runtime answers the cancellation" do
    turn = admitted_turn
    @message.discard_as_author!
    runtime = FakeRuntime.new(cancel_answer: { status: 0, body: {} })

    poll(turn, runtime)

    assert_empty runtime.submitted
    assert turn.reload.cancel_requested_at?
    assert_nil turn.finished_at
    assert_equal 1, ResidentTurn.occupying_capacity.count
  end

  test "an admitted turn whose dispatch still stands is submitted" do
    turn = admitted_turn
    runtime = FakeRuntime.new

    poll(turn, runtime)

    assert_equal [ turn.dispatch_id ], runtime.submitted
    assert_empty runtime.cancelled
    assert_equal "running", turn.reload.state
  end

  test "a turn the runtime already accepted is not withdrawn by a later loss" do
    turn = admitted_turn
    runtime = FakeRuntime.new
    poll(turn, runtime)
    @message.discard_as_author!
    runtime.known = true

    ResidentTurn.where(id: turn.id).update_all(poll_claimed_until: nil)
    poll(turn, runtime)

    assert_equal [ turn.dispatch_id ], runtime.submitted
    assert_empty runtime.cancelled
    assert_equal "running", turn.reload.state
  end

  private

  class FakeRuntime

    attr_reader :submitted, :cancelled
    attr_accessor :known

    def initialize(cancel_answer: nil)
      @ledger = SecureRandom.uuid
      @submitted = []
      @cancelled = []
      @cancel_answer = cancel_answer
      @known = false
    end

    def turn_status(id)
      return { status: 404, body: { "ledger_id" => @ledger } } unless @known

      { status: 200, body: { "ledger_id" => @ledger, "id" => id, "state" => "running" } }
    end

    def submit_turn(id, _payload, ledger_id:)
      @submitted << id
      { status: 202, body: { "id" => id, "state" => "running" } }
    end

    def cancel_turn(id, ledger_id:, payload: nil)
      @cancelled << id
      @cancel_answer || { status: 200, body: { "id" => id, "state" => "cancelled",
                                                "result" => { "status" => 409, "body" => { "status" => "cancelled" } } } }
    end

  end

  def admitted_turn
    turn = queued_claimed_turn
    Setting.instance.update!(resident_turn_limit: 1)
    assert_equal [ turn.id ], ResidentTurn.admit!
    turn
  end

  def poll(turn, runtime)
    ChaosTriggerClient.stub(:new, runtime) { ResidentTurnPollJob.perform_now(turn.id) }
  end

end
