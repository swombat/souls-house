require "test_helper"

# A VM resident's credential/service restart (#246 parity, Mira's #270
# review): tied to its exact start command, holding turn admission until it
# settles, reconciling services only on confirmed success.
module Agents
  class RemoteRefreshTest < ActiveJob::TestCase

    IMAGE = "sha256:#{'d' * 64}".freeze

    setup do
      @account = accounts(:personal_account)
      @agent = agents(:research_assistant)
      @agent.update!(runtime: "external", container_name: "hk-agent-refresh", trigger_bearer_token: "trig",
        runtime_ready_at: Time.current, uuid: SecureRandom.uuid_v7)
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
      @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32), reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @connection = @account.service_connections.create!(connected_by_user: users(:user_1), provider: "dropbox",
        external_subject_id: "dbid:refresh", external_identity: "refresh@example.test", management_scope: "personal",
        credential_kind: "oauth2", credential_payload_hash: { "access_token" => "t" },
        credential_metadata: { "granted_scopes" => Services::Catalog::DROPBOX_READ, "credential_strategy" => "self_refreshing" })
      @access = @agent.agent_service_accesses.create!(service_connection: @connection, enabled: true, follows_default: false)
      @access.update_columns(provisioning_status: "pending")
      @previous = ENV["SOULSHOUSE_DOMAIN"]
      ENV["SOULSHOUSE_DOMAIN"] = "souls.example"
    end

    teardown { ENV["SOULSHOUSE_DOMAIN"] = @previous }

    def begin_refresh
      RemoteRuntime.stub(:local_image_id, IMAGE) { RemoteRuntime.begin_refresh!(@agent) }
    end

    def answer(command, outcome)
      command.deliver!(now: Time.current)
      command.record_result!({ "outcome" => outcome, "error" => (outcome == "done" ? nil : "boom") }.compact, now: Time.current)
    end

    def queue_turn
      interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", session_id: SecureRandom.uuid,
        started_at: Time.current, endpoint_url: "https://runtime.example.test")
      ResidentTurn.enqueue!(interaction, { session_id: interaction.session_id, request: "hi" })
    end

    test "pending: the restart is queued, turns are held, services are not yet reconciled" do
      command = begin_refresh
      assert_equal "start_resident", command.kind
      assert_equal command.id, @placement.reload.refresh_command_id
      assert RemoteRuntime.refresh_pending?(@agent)
      ResidentTurn.stub(:enabled?, true) { assert_nil RemoteRuntime.enrollment_for(@agent) }
      assert_raises(ResidentTurn::SessionBusy) { queue_turn }
      assert_equal :pending, RemoteRuntime.settle_refresh!(@placement)
      assert_equal "pending", @access.reload.provisioning_status
    end

    test "done: services carried by the restart are reconciled and the hold released" do
      command = begin_refresh
      answer(command, "done")
      assert_equal :done, RemoteRuntime.settle_refresh!(@placement.reload)
      assert_equal "provisioned", @access.reload.provisioning_status
      assert_equal @connection.reload.credential_revision, @access.provisioned_revision
      assert_not RemoteRuntime.refresh_pending?(@agent)
    end

    test "a revision that changed while the restart was in flight is not marked" do
      command = begin_refresh
      @connection.update_columns(credential_revision: @connection.credential_revision + 1)
      answer(command, "done")
      RemoteRuntime.settle_refresh!(@placement.reload)
      assert_equal "pending", @access.reload.provisioning_status
      assert_not RemoteRuntime.refresh_pending?(@agent)
    end

    test "unknown, failed or refused keep the hold, stay visible, and recover through one tracked start" do
      %w[unknown failed refused].each do |outcome|
        @placement.update_columns(refresh_command_id: nil, refresh_snapshot: nil, refresh_last_error: nil)
        @access.update_columns(provisioning_status: "pending", provisioning_error_code: nil)
        command = begin_refresh
        answer(command, outcome)
        assert_equal :recovering, RemoteRuntime.stub(:local_image_id, IMAGE) { RemoteRuntime.settle_refresh!(@placement.reload) }, outcome
        assert RemoteRuntime.refresh_pending?(@agent), "#{outcome}: the hold stays"
        assert_raises(ResidentTurn::SessionBusy, outcome) { queue_turn }
        assert_equal "failed", @access.reload.provisioning_status, outcome
        assert_equal "vm_restart_#{outcome}", @access.provisioning_error_code
        assert_match(/VM restart with new credentials #{outcome}/, @agent.reload.sandbox_last_error)

        recovery = RunnerCommand.find(@placement.reload.refresh_command_id)
        assert_not_equal command, recovery
        assert_equal "start_resident", recovery.kind
        answer(recovery, "done")
        assert_equal :done, RemoteRuntime.settle_refresh!(@placement.reload), outcome
        assert_not RemoteRuntime.refresh_pending?(@agent), "#{outcome}: known state releases the hold"
        assert_equal "provisioned", @access.reload.provisioning_status, outcome
        assert_kind_of ResidentTurn, queue_turn
        ResidentTurn.update_all(finished_at: Time.current)
        AgentRuntimeInteraction.update_all(finished_at: Time.current)
      end
    end

    test "if the recovery start fails too, only an audited admin release opens admission" do
      answer(begin_refresh, "unknown")
      RemoteRuntime.stub(:local_image_id, IMAGE) { RemoteRuntime.settle_refresh!(@placement.reload) }
      answer(RunnerCommand.find(@placement.reload.refresh_command_id), "failed")
      assert_equal :held, RemoteRuntime.settle_refresh!(@placement.reload)
      assert RemoteRuntime.refresh_pending?(@agent)
      assert_equal 2, RunnerCommand.where(kind: "start_resident").count, "one recovery, no more"

      assert_raises(ArgumentError) { RemoteRuntime.release_refresh_hold!(@agent, by: users(:regular_user), reason: "looked") }
      assert_raises(ArgumentError) { RemoteRuntime.release_refresh_hold!(@agent, by: users(:site_admin_user), reason: " ") }
      assert RemoteRuntime.release_refresh_hold!(@agent, by: users(:site_admin_user), reason: "container checked by hand")
      assert_not RemoteRuntime.refresh_pending?(@agent)
      assert AuditLog.exists?(action: "vm_refresh_hold_released", auditable: @placement)
      assert_match(/failed/, @placement.reload.refresh_last_error, "the error stays visible after release")
    end

    test "a runner that never answers keeps the hold past the bound, with the error visible" do
      begin_refresh
      travel RemoteRuntime::REFRESH_ANSWER_WITHIN + 1.minute do
        assert_equal :held, RemoteRuntime.settle_refresh!(@placement.reload)
        assert RemoteRuntime.refresh_pending?(@agent), "an unanswered start may still run"
        assert_raises(ResidentTurn::SessionBusy) { queue_turn }
        assert_match(/no answer/, @placement.reload.refresh_last_error)
        assert_equal 1, RunnerCommand.where(kind: "start_resident").count, "no recovery queued behind an unanswered start"
      end
    end

    test "refresh admission and turn admission exclude each other" do
      queue_turn
      assert_equal :busy, begin_refresh
      assert_nil @placement.reload.refresh_command_id
      assert_equal 0, RunnerCommand.where(kind: "start_resident").count

      ResidentTurn.update_all(finished_at: Time.current)
      AgentRuntimeInteraction.update_all(finished_at: Time.current)
      assert_kind_of RunnerCommand, begin_refresh
      assert_raises(ResidentTurn::SessionBusy) { queue_turn }
      assert_equal :busy, begin_refresh, "one refresh at a time"
    end

    test "a VM backup hold makes the refresh busy under the turn gate, and the job defers without local Docker" do
      Backup::VmResident.stub(:held?, true) do
        assert_equal :busy, begin_refresh
      end
      Agents::Sandbox.stub(:new, ->(*) { flunk "must not inspect local Docker" }) do
        RemoteRuntime.stub(:running?, true) do
          Backup::VmResident.stub(:held?, true) do
            assert_enqueued_with(job: AccountAgentCredentialsRefreshJob, args: [ @account.id, @agent.id ]) do
              AccountAgentCredentialsRefreshJob.perform_now(@account.id, @agent.id)
            end
          end
          assert_nil @placement.reload.refresh_command_id
          RemoteRuntime.stub(:local_image_id, IMAGE) do
            assert_enqueued_with(job: RemoteRefreshSettleJob, args: [ @placement.id ]) do
              AccountAgentCredentialsRefreshJob.perform_now(@account.id, @agent.id)
            end
          end
          assert @placement.reload.refresh_command_id
          assert_equal "pending", @access.reload.provisioning_status, "not reconciled when only queued"
        end
      end
    end

  end
end
