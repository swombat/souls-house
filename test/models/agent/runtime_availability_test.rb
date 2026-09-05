require "test_helper"

class Agent::RuntimeAvailabilityTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
  end

  test "only supported runtime states can be newly assigned" do
    %w[inline migrating].each do |runtime|
      @agent.runtime = runtime
      assert_not @agent.valid?
      assert @agent.errors[:runtime].any?
    end
    assert_equal "deprecated", Agent.new.runtime
  end

  test "legacy and deprecated states fail closed without changing historical records" do
    %w[inline migrating deprecated].each do |runtime|
      @agent.update_columns(runtime: runtime)
      assert @agent.deprecated?
      assert_not @agent.hosted?
      assert_not Agent.hosted.exists?(@agent.id)
      assert_not Agent.eligible_for_conversation.exists?(@agent.id)
      error = assert_raises(Agent::RuntimeAvailability::Unavailable) { @agent.require_conversation_runtime! }
      assert_equal "agent_deprecated", error.code
      assert_equal runtime, @agent.reload.runtime
    end
  end

  test "paused and offline are not deprecated; provisioning cannot join conversations" do
    %w[external offline].each do |runtime|
      @agent.update_columns(runtime: runtime, paused: true)
      assert @agent.eligible_for_conversation?
      assert_not @agent.deprecated?
    end
    @agent.update_columns(runtime: "provisioning")
    assert @agent.hosted?
    assert_not @agent.eligible_for_conversation?
    @agent.update_columns(runtime: "external", active: false)
    assert_not @agent.eligible_for_conversation?
  end

  test "agent credentials stop authenticating but owner credentials remain usable" do
    @agent.update_columns(runtime: "external")
    key = ApiKey.generate_for(@agent.account.owner, name: "resident", agent: @agent)
    owner_key = ApiKey.generate_for(@agent.account.owner, name: "owner")
    assert_equal key, ApiKey.authenticate(key.raw_token)
    @agent.update_columns(runtime: "deprecated")
    assert_nil ApiKey.authenticate(key.raw_token)
    assert_equal owner_key, ApiKey.authenticate(owner_key.raw_token)
  end

  test "stale dispatch skips deprecated agents without creating a message or sandbox" do
    @agent.update_columns(runtime: "deprecated")
    chat = @agent.account.chats.create!(manual_responses: true, agents: [ @agent ])
    clear_enqueued_jobs
    notices = []
    ActionCable.server.stub(:broadcast, ->(*args) { notices << args }) do
      assert_no_difference "Message.count" do
        ManualAgentResponseJob.perform_now(chat, @agent)
      end
    end
    assert_equal "agent_skipped", notices.last.last[:action]
    assert_equal "agent_deprecated", notices.last.last[:reason]
    assert_raises(Agent::RuntimeAvailability::Unavailable) { chat.trigger_agent_response!(@agent) }
    assert_raises(Agent::RuntimeAvailability::Unavailable) { chat.trigger_all_agents_response! }
    assert_no_enqueued_jobs { chat.trigger_mentioned_agents!("@#{@agent.name}") }
  end

  test "skipping a member advances the all agent chain" do
    @agent.update_columns(runtime: "deprecated")
    other = agents(:code_reviewer)
    other.update_columns(runtime: "external")
    chat = @agent.account.chats.create!(manual_responses: true, agents: [ @agent, other ])
    clear_enqueued_jobs
    assert_enqueued_with(job: AllAgentsResponseJob, args: [ chat, [ other.id ] ]) do
      AllAgentsResponseJob.perform_now(chat, [ @agent.id, other.id ])
    end
  end

  test "retired sandbox admission does not inspect or clean up containers" do
    @agent.update_columns(runtime: "deprecated")
    sandbox = Agents::Sandbox.new(@agent)
    sandbox.stub :container_exists?, -> { flunk "Must not inspect a retired container" } do
      sandbox.stub :stop_if_idle!, -> { flunk "Must not clean up a retired container" } do
        Agents::Config.stub :cold_start?, true do
          assert_raises(Agents::Sandbox::SandboxError) { sandbox.spawn! }
          assert_raises(Agents::Sandbox::SandboxError) { sandbox.recreate! }
          assert_raises(Agents::Sandbox::SandboxError) { sandbox.with_runtime { flunk "Must not yield" } }
        end
      end
    end
  end

  test "old provisioning job names cannot promote a retired agent" do
    @agent.update_columns(runtime: "deprecated")
    Agents::Volume.stub :new, ->(*) { flunk "Must not touch a retired identity" } do
      assert_no_enqueued_jobs do
        ProvisionAgentJob.perform_now(@agent.id)
        PromoteAgentJob.perform_now(@agent.id)
      end
    end
  end

end
