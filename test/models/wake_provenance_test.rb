require "test_helper"

class WakeProvenanceTest < ActiveSupport::TestCase

  setup do
    @user = users(:user_1)
    @account = @user.personal_account
    @account.update!(use_system_ai_credentials: false, openrouter_api_key: "test-only-router")
    @first = @account.agents.create!(name: "First", system_prompt: "Test", runtime: "external")
    @second = @account.agents.create!(name: "Second", system_prompt: "Test", runtime: "external")
    @chat = @account.chats.create!(title: "Provenance", manual_responses: true, agents: [ @first, @second ])
  end

  test "authenticated principal survives immediate reservation independently of display label" do
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      @chat.request_agent_response!(@first, requested_by: "a scheduler", user: @user)
      @chat.request_agent_response!(@second, requested_by: "Daniel", requester_agent: @first)
    end
    assert_equal [ "human" ], run_for(@first).wake_source_kinds
    assert_equal [ "peer" ], run_for(@second).wake_source_kinds
  end

  test "a display label without a principal remains unknown" do
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      @chat.request_agent_response!(@first, requested_by: @user.email_address)
    end
    assert_empty run_for(@first).wake_source_kinds
  end

  test "live activity off carries provenance in the queued job" do
    AgentRuntimeInteraction.stub :live_activity_enabled?, false do
      assert_enqueued_with(job: ManualAgentResponseJob,
        args: [ @chat, @first, { wake_source_kinds: [ "human" ] } ]) do
        @chat.request_agent_response!(@first, requested_by: "person", user: @user)
      end
    end
  end

  test "ask all gives every free recipient the authenticated source" do
    assert_enqueued_with(job: AllAgentsResponseJob,
      args: [ @chat, [ @first.id, @second.id ], { wake_source_kinds: [ "peer" ] } ]) do
      @chat.request_all_agents_response!(requested_by: "resident", requester_agent: @first)
    end
    AllAgentsResponseJob.perform_now(@chat, [ @first.id, @second.id ], wake_source_kinds: [ "peer" ])
    assert_equal [ [ "peer" ], [ "peer" ] ], @chat.agent_runtime_interactions.order(:id).pluck(:wake_source_kinds)
  end

  test "held human and peer sources stay mixed and withdrawn sources stop describing the wake" do
    @chat.messages.create!(role: "assistant", agent: @second, content: "Please review")
    wake = PendingWake.queue!(chat: @chat, agent: @first, requested_by: "resident", requester_agent: @second)
    PendingWake.queue!(chat: @chat, agent: @first, requested_by: "human", user: @user)
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      PendingWake.release!(chat: @chat, agent: @first)
    end
    run = wake.reload.released_interaction
    assert_equal %w[human peer], run.wake_source_kinds.sort
    @chat.chat_agents.find_by!(agent: @second).destroy!
    assert run.claim_dispatch!
    assert_equal [ "human" ], run.reload.wake_source_kinds
  end

  test "scheduled held wakes retain the scheduler rather than its standing resident authority" do
    @chat.messages.create!(role: "system", content: "Repository changed")
    wake = PendingWake.queue!(chat: @chat, agent: @first, requested_by: "watch", requester_agent: @first,
      wake_source_kinds: [ "scheduled" ])
    assert_equal [ "scheduled" ], wake.standing_source_kinds
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      PendingWake.release!(chat: @chat, agent: @first)
    end
    assert_equal [ "scheduled" ], wake.reload.released_interaction.wake_source_kinds
  end

  test "legacy held source without recorded provenance stays unknown" do
    wake = PendingWake.queue!(chat: @chat, agent: @first, requested_by: "person", user: @user)
    wake.sources.sole.update!(wake_source_kinds: [])
    assert_equal [ "unknown" ], wake.standing_source_kinds
  end

  test "resident message handoff records peer provenance before the job runs" do
    message = @chat.messages.create!(role: "assistant", agent: @first, content: "Review please",
      handoff_recipient_ids: [ @second.id ])
    handoff = message.handoffs.sole
    AgentRuntimeInteraction.stub :live_activity_enabled?, true do
      handoff.dispatch!
    end
    assert_equal [ "peer" ], handoff.reload.runtime_interaction.wake_source_kinds
  end

  test "human message dispatch records human provenance" do
    message = Messages::PostFromHuman.new(chat: @chat, user: @user, content: "@First please review").call.message
    message.message_dispatch.reserve!
    assert_equal [ "human" ], message.message_dispatch.reload.runtime_interaction.wake_source_kinds
  end

  test "rhythm dispatch records scheduled provenance even for a human creator" do
    rhythm = Rhythm.create!(account: @account, creator: @user, agents: [ @first ],
      title: "Returning", opening: "Please reflect", cadence: "daily", time_of_day: "09:00", timezone: "UTC")
    occurrence = rhythm.fire!(manual: true, request_key: SecureRandom.uuid).occurrence
    occurrence.message.message_dispatch.reserve!
    assert_equal [ "scheduled" ], occurrence.message.message_dispatch.reload.runtime_interaction.wake_source_kinds
  end

  test "delayed resident invitation has peer provenance and reason does not supply authority" do
    assert_enqueued_with(job: ManualAgentResponseJob,
      args: ->(args) { args[1] == @second && args.last == { wake_source_kinds: [ "peer" ] } }) do
      Chat.initiate_by_agent!(@first, topic: "Invitation", message: "Please visit",
        reason: "A human told me to", invite_agent_ids: [ @second.to_param ])
    end
  end

  private

  def run_for(agent)
    @chat.agent_runtime_interactions.find_by!(agent: agent)
  end

end
