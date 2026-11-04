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

  [ false, true ].each do |remote|
    location = remote ? "remote" : "local"

    test "account refresh skips an inactive #{location} resident and refreshes a later active resident" do
      inactive, active = credential_refresh_agents(remote: remote)
      sandbox = Minitest::Mock.new
      runtime = Minitest::Mock.new

      if remote
        runtime.expect(:running?, true, [ active ])
        runtime.expect(:begin_refresh!, :queued, [ active ])
      else
        sandbox.expect(:active_turn?, false)
        sandbox.expect(:recreate!, true)
      end

      Agents::RemoteRuntime.stub(:running?, ->(agent) { runtime.running?(agent) }) do
        Agents::RemoteRuntime.stub(:begin_refresh!, ->(agent) { runtime.begin_refresh!(agent) }) do
          Agents::Sandbox.stub(:new, ->(agent) {
            assert_not remote, "must not touch local Docker for a VM resident"
            assert_equal active.id, agent.id, "must skip the earlier inactive resident"
            sandbox
          }) do
            if remote
              assert_enqueued_with(job: RemoteRefreshSettleJob, args: [ active.placement.id ]) do
                AccountAgentCredentialsRefreshJob.perform_now(inactive.account_id)
              end
            else
              assert_no_enqueued_jobs do
                AccountAgentCredentialsRefreshJob.perform_now(inactive.account_id)
              end
            end
          end
        end
      end

      assert sandbox.verify
      assert runtime.verify
    end

    test "targeted inactive #{location} refresh is a no-op including manifest-only calls" do
      inactive, = credential_refresh_agents(remote: remote)

      Agents::RemoteRuntime.stub(:running?, ->(*) { flunk "must not inspect inactive runtime" }) do
        Agents::RemoteRuntime.stub(:begin_refresh!, ->(*) { flunk "must not refresh inactive runtime" }) do
          Agents::Sandbox.stub(:new, ->(*) { flunk "must not touch inactive sandbox" }) do
            Agents::ServiceManifest.stub(:new, ->(*) { flunk "must not build inactive manifest" }) do
              assert_no_enqueued_jobs do
                AccountAgentCredentialsRefreshJob.perform_now(inactive.account_id, inactive.id)
                AccountAgentCredentialsRefreshJob.perform_now(inactive.account_id, inactive.id, manifest_only: true)
              end
            end
          end
        end
      end
    end
  end

  test "manifest-only account refresh skips inactive residents and reconciles a later active resident" do
    inactive, active = credential_refresh_agents(remote: false)
    sandbox = Minitest::Mock.new
    sandbox.expect(:refresh_service_manifest!, true, [], yaml: "synthetic manifest")
    manifest = Minitest::Mock.new
    manifest.expect(:to_yaml, "synthetic manifest")
    manifest.expect(:mark_reconciled!, true)

    Agents::Sandbox.stub(:new, ->(agent) {
      assert_equal active.id, agent.id
      sandbox
    }) do
      Agents::ServiceManifest.stub(:new, ->(agent) {
        assert_equal active.id, agent.id
        manifest
      }) do
        assert_no_enqueued_jobs do
          AccountAgentCredentialsRefreshJob.perform_now(inactive.account_id, manifest_only: true)
        end
      end
    end

    assert sandbox.verify
    assert manifest.verify
  end

  test "unrelated refresh errors still propagate" do
    agent = agents(:research_assistant)
    agent.update!(container_name: "hk-agent-test")

    Agents::Sandbox.stub(:new, ->(*) { raise ArgumentError, "synthetic refresh failure" }) do
      error = assert_raises(ArgumentError) do
        AccountAgentCredentialsRefreshJob.new.perform(agent.account_id, agent.id)
      end
      assert_equal "synthetic refresh failure", error.message
    end
  end

  test "manifest-only refresh rechecks inactivity under the resident lock" do
    agent = agents(:research_assistant)
    agent.update!(container_name: "hk-agent-test")

    Agents::Sandbox.stub(:new, ->(resident) {
      Agent.where(id: resident.id).update_all(active: false)
      Minitest::Mock.new
    }) do
      Agents::ServiceManifest.stub(:new, ->(*) { flunk "must not write a manifest after deactivation" }) do
        assert_no_enqueued_jobs do
          AccountAgentCredentialsRefreshJob.perform_now(agent.account_id, agent.id, manifest_only: true)
        end
      end
    end
  end

  private

  def credential_refresh_agents(remote:)
    inactive, active = [ agents(:research_assistant), agents(:code_reviewer) ].sort_by(&:id)
    inactive.update_columns(active: false, runtime: "external", container_name: "hk-agent-inactive")
    active.update_columns(active: true, runtime: "external", container_name: "hk-agent-active")

    if remote
      [ inactive, active ].each do |agent|
        AgentPlacement.create!(agent:, backend: "hetzner_cloud", state: "ready", provider_server_id: agent.id)
      end
    end

    [ inactive, active ]
  end

end
