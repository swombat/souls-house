require "test_helper"

class Chat::ParticipantRemovalTest < ActiveSupport::TestCase

  include ActiveJob::TestHelper

  setup do
    @user = users(:user_1)
    @agent = agents(:research_assistant)
    @other = agents(:code_reviewer)
    @chat = @agent.account.chats.create!(manual_responses: true, agents: [ @agent, @other ])
  end

  test "removal drops pending holds and handoffs permanently across rejoining" do
    message = @chat.messages.create!(role: "assistant", agent: @other, content: "Review please")
    handoff = MessageHandoff.create!(chat: @chat, message: message, requester_agent: @other,
      recipient_agent: @agent, source: "field")
    wake = PendingWake.queue!(chat: @chat, agent: @agent, requested_by: "person", user: @user)
    @chat.remove_participant!(@agent, by: @user)
    assert_equal "not_in_room", wake.reload.drop_reason
    assert_equal [ "blocked", "not_in_room" ], [ handoff.reload.status, handoff.reason ]

    travel 1.second do
      @chat.chat_agents.create!(agent: @agent)
      assert_no_difference "AgentRuntimeInteraction.count" do
        PendingWake.release!(chat: @chat, agent: @agent)
        handoff.dispatch!
      end
    end
  end

  test "old human message dispatch cannot reserve a rejoined resident" do
    message = @chat.messages.create!(role: "user", user: @user, content: "A request")
    dispatch = MessageDispatch.accept!(message: message, target_agent_ids: [ @agent.id ])
    rejoin
    assert_no_difference "AgentRuntimeInteraction.count" do
      dispatch.reserve!
    end
    assert_equal "cancelled", dispatch.reload.status
  end

  test "old ask all job skips a rejoined resident but wakes unchanged seats" do
    job = AllAgentsResponseJob.new(@chat, [ @agent.id, @other.id ])
    job.enqueued_at = Time.current
    rejoin
    job.perform_now
    assert_not @chat.agent_runtime_interactions.exists?(agent: @agent)
    assert @chat.agent_runtime_interactions.exists?(agent: @other)
  end

  test "old manual job never calls runtime after removal and rejoin" do
    job = ManualAgentResponseJob.new(@chat, @agent)
    job.enqueued_at = Time.current
    rejoin
    ExternalAgentResponseRequest.stub(:new, ->(**) { flunk "stale request reached runtime" }) do
      assert_no_difference "AgentRuntimeInteraction.count" do
        job.perform_now
      end
    end
  end

  test "nonreserved ask all forwards the original request time to manual jobs" do
    requested_at = Time.current
    job = AllAgentsResponseJob.new(@chat, [ @agent.id ], requested_at: requested_at)
    job.stub(:live_reservations?, false) do
      assert_enqueued_with(job: ManualAgentResponseJob,
        args: [ @chat, @agent, { wake_source_kinds: [], requested_at: requested_at } ]) do
        job.perform_now
      end
    end
  end

  test "three resident chain keeps its original request time across every hop" do
    third = agents(:without_tools)
    @chat.chat_agents.create!(agent: third)
    run = AgentRuntimeInteraction.reserve!(chat: @chat, agent: @other,
      response_chain_agent_ids: [ third.id, @agent.id ])
    origin = run.response_requested_at
    rejoin

    run.finish_execution!("completed")
    AllAgentsResponseJob.perform_now(@chat, [ third.id, @agent.id ], after_interaction_id: run.id)
    second = @chat.agent_runtime_interactions.find_by!(agent: third)
    assert_equal origin, second.response_requested_at
    second.finish_execution!("completed")
    assert_no_difference "AgentRuntimeInteraction.count" do
      AllAgentsResponseJob.perform_now(@chat, [ @agent.id ], after_interaction_id: second.id)
    end
    assert_not @chat.agent_runtime_interactions.exists?(agent: @agent)
  end

  test "busy retry cannot recreate a request for a new seat" do
    busy = AgentRuntimeInteraction.reserve!(agent: @agent, chat: @chat,
      wake_source_kinds: [ "human" ], requested_by_user: @user)
    busy.finish_execution!("busy")
    rejoin
    assert_no_difference "PendingWake.count" do
      BusyRunRetryJob.perform_now(busy.id)
    end
  end

  test "reservation itself rechecks request age inside chat lock" do
    requested_at = Time.current
    rejoin
    assert_raises(ArgumentError) do
      AgentRuntimeInteraction.reserve!(chat: @chat, agent: @agent, requested_at: requested_at)
    end
    assert AgentRuntimeInteraction.reserve!(chat: @chat, agent: @agent)
  end

  private

  def rejoin
    @chat.remove_participant!(@agent, by: @user)
    travel 1.second
    @chat.chat_agents.create!(agent: @agent)
  end

end
