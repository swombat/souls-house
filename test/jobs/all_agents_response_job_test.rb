require "test_helper"

class AllAgentsResponseJobTest < ActiveJob::TestCase

  setup do
    @first = agents(:research_assistant)
    @second = agents(:code_reviewer)
    @chat = @first.account.chats.create!(title: "All harnesses", manual_responses: true, agents: [ @first, @second ])
  end

  test "dispatches first resident and queues the remaining chain" do
    ManualAgentResponseJob.stub(:perform_now, ->(*) { flunk "must not wait for reflection" }) do
      assert_enqueued_jobs 1, only: ManualAgentResponseJob do
        AllAgentsResponseJob.perform_now(@chat, [ @first.id, @second.id ])
      end
    end
    run = @chat.agent_runtime_interactions.sole
    assert_equal @first, run.agent
    assert_equal [ @second.id ], run.response_chain_agent_ids
    assert_nil run.finished_at
    assert_nil run.response_chain_advanced_at
  end

  test "a committed linked reply advances once without releasing the resident" do
    run = AgentRuntimeInteraction.reserve!(agent: @first, chat: @chat, response_chain_agent_ids: [ @second.id ])
    run.claim_dispatch!
    run.activity_configuration!
    assert_enqueued_with(job: AllAgentsResponseJob, args: [ @chat, [ @second.id ], { after_interaction_id: run.id } ]) do
      @chat.messages.create!(agent: @first, role: "assistant", content: "Published reply", runtime_interaction: run)
    end
    AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id)
    assert run.reload.response_chain_advanced_at?
    assert_nil run.finished_at
    assert_equal "preparing", run.execution_state
    assert @chat.agent_response_active?(@first)
    assert_raises(ArgumentError) { AgentRuntimeInteraction.reserve!(agent: @first, chat: @chat) }
    assert_no_enqueued_jobs only: AllAgentsResponseJob do
      @chat.messages.create!(agent: @first, role: "assistant", content: "Second posted part", runtime_interaction: run)
      run.finish_execution!("completed")
      run.advance_response_chain!
    end
    assert_no_difference "AgentRuntimeInteraction.count" do
      AllAgentsResponseJob.perform_now(@chat, [ @second.id ], after_interaction_id: run.id)
    end
  end

  test "silent confirmed completion advances but ambiguous completion does not" do
    run = AgentRuntimeInteraction.reserve!(agent: @first, chat: @chat, response_chain_agent_ids: [ @second.id ])
    assert_no_enqueued_jobs only: AllAgentsResponseJob do
      run.advance_response_chain!
    end
    assert_enqueued_with(job: AllAgentsResponseJob, args: [ @chat, [ @second.id ], { after_interaction_id: run.id } ]) do
      run.finish_execution!("completed")
    end
    other = AgentRuntimeInteraction.reserve!(agent: @first, chat: @chat, response_chain_agent_ids: [ @second.id ])
    assert_no_enqueued_jobs only: AllAgentsResponseJob do
      other.finish_execution!("outcome_unknown")
    end
    assert_nil other.reload.response_chain_advanced_at
  end

  test "unlinked messages cannot advance a chain and archived chats stop it" do
    run = AgentRuntimeInteraction.reserve!(agent: @first, chat: @chat, response_chain_agent_ids: [ @second.id ])
    assert_no_enqueued_jobs only: AllAgentsResponseJob do
      @chat.messages.create!(agent: @first, role: "assistant", content: "Unlinked reply")
      @chat.archive!
      run.finish_execution!("completed")
    end
    assert_nil run.reload.response_chain_advanced_at
  end

  test "removed participants do not stall the remaining chain" do
    @chat.chat_agents.find_by!(agent: @first).destroy!
    ManualAgentResponseJob.stub(:perform_now, ->(*) { flunk "removed participant" }) do
      assert_enqueued_with(job: AllAgentsResponseJob, args: [ @chat, [ @second.id ] ]) do
        AllAgentsResponseJob.perform_now(@chat, [ @first.id, @second.id ])
      end
    end
  end

  test "empty and archived chains do not dispatch" do
    ManualAgentResponseJob.stub(:perform_now, ->(*) { flunk "must not dispatch" }) do
      assert_no_enqueued_jobs do
        AllAgentsResponseJob.perform_now(@chat, [])
        @chat.archive!
        AllAgentsResponseJob.perform_now(@chat, [ @first.id ])
      end
    end
  end

end
