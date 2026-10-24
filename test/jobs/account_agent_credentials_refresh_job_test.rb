require "test_helper"

class AccountAgentCredentialsRefreshJobTest < ActiveJob::TestCase

  test "recreates externally hosted account agents" do
    agent = agents(:research_assistant)
    agent.update!(runtime: "external", container_name: "hk-agent-test")
    sandbox = Minitest::Mock.new
    sandbox.expect(:active_turn?, false)
    sandbox.expect(:recreate!, true)

    Agents::Sandbox.stub(:new, sandbox) do
      AccountAgentCredentialsRefreshJob.perform_now(agent.account.id)
    end

    assert sandbox.verify
  end

  test "defers an active agent runtime" do
    agent = agents(:research_assistant)
    agent.update!(runtime: "external", container_name: "hk-agent-test")
    sandbox = Minitest::Mock.new
    sandbox.expect(:active_turn?, true)

    Agents::Sandbox.stub(:new, sandbox) do
      assert_enqueued_with(
        job: AccountAgentCredentialsRefreshJob,
        args: [ agent.account.id, agent.id ]
      ) do
        AccountAgentCredentialsRefreshJob.perform_now(agent.account.id)
      end
    end

    assert sandbox.verify
  end


  test "a running VM resident begins a tracked refresh, never a local recreate" do
    agent = agents(:research_assistant)
    agent.update!(runtime: "external", container_name: "hk-agent-vm", runtime_ready_at: Time.current)
    AgentPlacement.create!(agent:, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
    begun = []
    Agents::RemoteRuntime.stub(:running?, true) do
      Agents::RemoteRuntime.stub(:begin_refresh!, ->(a) { begun << a.id; :queued }) do
        Agents::Sandbox.stub(:new, ->(*) { flunk "must not touch local Docker" }) do
          assert_enqueued_with(job: RemoteRefreshSettleJob) do
            AccountAgentCredentialsRefreshJob.perform_now(agent.account.id, agent.id)
          end
        end
      end
    end
    assert_equal [ agent.id ], begun
  end

  test "a VM resident mid-birth or not running is left alone" do
    agent = agents(:research_assistant)
    agent.update!(runtime: "external", container_name: "hk-agent-vm")
    AgentPlacement.create!(agent:, backend: "hetzner_cloud", state: "pending")
    Agents::RemoteRuntime.stub(:start!, ->(*) { flunk "must not start" }) do
      Agents::Sandbox.stub(:new, ->(*) { flunk "must not touch local Docker" }) do
        AccountAgentCredentialsRefreshJob.perform_now(agent.account.id, agent.id)
      end
    end
  end

end
