require "test_helper"

module Backup
  class VmResidentTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.update!(restic_password: "synthetic-restic-password", uuid: SecureRandom.uuid)
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
      @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32),
        reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
    end

    def issue
      VmResident.issue!(placement: @placement)
    end

    def answer(command, outcome: "done", unpaused: true, **values)
      backup = VmBackup.find_by!(runner_command: command)
      command.deliver!(now: Time.current)
      command.record_result!({ "outcome" => outcome, "result" => {
        "snapshot_id" => "a" * 64, "checkpoint_digest" => backup.checkpoint_digest,
        "checkpoint_file_sha256" => backup.checkpoint_file_digest, "unpaused" => unpaused,
        "size_bytes" => 42, "duration_ms" => 12, "tools_stopped" => true
      }.merge(values.stringify_keys) }, now: Time.current)
    end

    test "issue holds dispatch and stores only encrypted checkpoint bytes and password" do
      command = issue
      assert_equal "backup_resident", command.kind
      assert VmResident.held?(@agent)
      assert_not Agents::RuntimeLocation.dispatchable?(@agent)
      payload = JSON.parse(command.payload_json)
      assert_equal "synthetic-restic-password", payload["restic_password"]
      assert_equal Digest::SHA256.hexdigest(payload["checkpoint_json"]), payload["checkpoint_file_sha256"]
      raw = RunnerCommand.connection.select_value("SELECT payload_json FROM runner_commands WHERE id = #{command.id}")
      assert_not_includes raw, "synthetic-restic-password"
      assert_raises(VmResident::Unavailable) { issue }
      assert_raises(Agent::RuntimeAvailability::Unavailable) do
        AgentRuntimeInteraction.record_trigger!(agent: @agent, chat: nil, trigger_kind: "wake",
          conversation_id: nil, requested_by: "test", session_id: "held", endpoint_url: "runner:test", request_text: "") { flunk }
      end
    end

    test "invalid UUID refuses before any backup hold or runner command is issued" do
      @agent.update_column(:uuid, nil)
      assert_no_difference [ "VmBackup.count", "RunnerCommand.count" ] do
        assert_raises(VmResident::Unavailable) { issue }
      end
    end

    test "active interaction and uncertain runtime turn prevent issuing a checkpoint" do
      interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", started_at: Time.current)
      assert_raises(AgentRestic::ResidentBusy) { issue }
      interaction.update!(finished_at: Time.current)
      ResidentTurn.create!(agent: @agent, agent_runtime_interaction: interaction, state: "unknown",
        session_id: "uncertain", dispatch_id: SecureRandom.uuid, payload: "{}")
      assert_raises(AgentRestic::ResidentBusy) { issue }
      assert_empty VmBackup.all
    end

    test "delivered lifecycle commands prevent issuing a backup" do
      command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "start_resident", payload: {})
      command.deliver!(now: Time.current)
      assert_raises(AgentRestic::ResidentBusy) { issue }
    end

    test "only the current generation's lifecycle commands make the resident busy" do
      seed = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "seed_home", payload: {})
      start = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "start_resident", payload: {})
      start.update!(state: "unknown")
      assert VmResident.busy?(@agent), "this generation's uncertainty blocks"

      # A retried activation: the last attempt's server is gone and its runner
      # revoked, and the placement moved on to the next generation.
      @enrollment.revoke!
      @placement.update!(generation: 2)
      assert_equal %w[queued unknown], [ seed.reload.state, start.reload.state ]
      assert_not VmResident.busy?(@agent), "a superseded generation's commands do not"

      @enrollment, token = RunnerEnrollment.mint!(placement: @placement)
      @enrollment.confirm_provider_server!(4242)
      @enrollment.enroll!(token:, public_key: Base64.strict_encode64("k" * 32),
        reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      @enrollment.heartbeat!(reported_server_id: 4242, facts: {}, nonce: SecureRandom.hex(16))
      assert issue, "the retry's first backup is admitted"
      VmBackup.update_all(state: "verified", released_at: Time.current)
      current = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "seed_home", payload: {})
      current.deliver!(now: Time.current)
      assert VmResident.busy?(@agent), "the new generation's own delivered seed still blocks"
      assert_raises(AgentRestic::ResidentBusy) { issue }
    end

    test "a reconciled finished turn no longer stays busy because its submit acknowledgement was unknown" do
      interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake",
        started_at: 1.minute.ago, finished_at: Time.current)
      turn = ResidentTurn.create!(agent: @agent, agent_runtime_interaction: interaction, state: "unknown",
        session_id: "reconciled", dispatch_id: SecureRandom.uuid, payload: "{}")
      command = RunnerCommand.enqueue!(enrollment: @enrollment, kind: "submit_turn", payload: {}, resident_turn: turn)
      command.update!(state: "unknown")
      assert VmResident.busy?(@agent)
      turn.update!(state: "finished", finished_at: Time.current)
      assert_not VmResident.busy?(@agent)
    end

    test "verified snapshot is recorded once and releases the hold" do
      command = issue
      answer(command)
      verifier = Minitest::Mock.new
      verifier.expect(:verify!, true, [], agent: @agent, snapshot_id: "a" * 64,
        checkpoint_digest: nil, checkpoint_file_digest: Digest::SHA256.hexdigest("null"))
      result = VmResident.status(command:, verifier:)
      assert_equal "verified", result[:state]
      assert result[:snapshot].ok?
      assert_not VmResident.held?(@agent)
      assert_equal result[:snapshot].id, VmResident.status(command:, verifier:)[:snapshot].id
      verifier.verify
    end

    test "checkpoint mismatch never asks the verifier and records failed backup" do
      command = issue
      answer(command, checkpoint_file_sha256: "wrong")
      result = VmResident.status(command:, verifier: Object.new)
      assert_equal "failed", result[:state]
      assert_not result[:snapshot].ok?
      assert_not VmResident.held?(@agent)
    end

    test "missing storage proof fails even when runner claims done" do
      command = issue
      answer(command)
      verifier = Object.new
      def verifier.verify!(**)
        raise VmSnapshotVerifier::Invalid, "Snapshot missing"
      end
      result = VmResident.status(command:, verifier:)
      assert_equal "failed", result[:state]
      assert_equal "Snapshot missing", result[:reason]
    end

    test "a failed runner answer records the runner's own error, not just its state" do
      command = issue
      command.deliver!(now: Time.current)
      command.record_result!({ "outcome" => "failed", "error" => "restic backup failed",
        "result" => { "unpaused" => true, "tools_stopped" => true, "snapshot_id" => nil } }, now: Time.current)
      result = VmResident.status(command:, verifier: Object.new)
      assert_equal "failed", result[:state]
      assert_equal "Runner backup failed: restic backup failed", result[:reason]
      assert_equal "Runner backup failed: restic backup failed", result[:snapshot].stderr_tail
      assert_not VmResident.held?(@agent)
    end

    test "a failed or latched Postgres dump fails the backup with its reason and never verifies" do
      command = issue
      answer(command, postgres_dump: { "state" => "failed",
        "reason" => "incomplete generation 20261113T040000Z retained; operator review required" })
      result = VmResident.status(command:, verifier: Object.new)
      assert_equal "failed", result[:state]
      assert_equal "Postgres dump failed: incomplete generation 20261113T040000Z retained; operator review required",
        result[:reason]
      assert_equal "a" * 64, result[:snapshot].restic_snapshot_id, "the rest of the snapshot is still on record"
      assert_not result[:snapshot].ok?
      assert_not VmResident.held?(@agent), "a dump failure is not a containment failure"
    end

    test "an ok or absent Postgres dump, or a runner too old to report one, still verifies" do
      [ { "state" => "ok", "generation" => "20261113T040000Z", "bytes" => 9 }, { "state" => "absent" }, nil ].each do |dump|
        VmBackup.update_all(state: "verified", released_at: Time.current)
        command = issue
        values = dump.nil? ? {} : { postgres_dump: dump }
        answer(command, **values)
        verifier = Object.new
        def verifier.verify!(**) = true
        assert_equal "verified", VmResident.status(command:, verifier:)[:state], dump.inspect
      end
    end

    test "deadline or unknown unpause never silently releases a resident" do
      command = issue
      backup = VmBackup.find_by!(runner_command: command)
      backup.update!(deadline_at: 1.second.ago)
      assert_equal "failed", VmResident.status(command:, verifier: Object.new)[:state]
      assert VmResident.held?(@agent)
      answer(command, outcome: "unknown", unpaused: false)
      assert_equal "failed", VmResident.status(command:, verifier: Object.new)[:state]
      assert VmResident.held?(@agent)
    end

    test "cleanup release requires retirement and runner revocation" do
      issue
      assert_raises(VmResident::Unavailable) { VmResident.release_after_retirement!(placement: @placement) }
      @placement.update!(state: "retired")
      assert_raises(VmResident::Unavailable) { VmResident.release_after_retirement!(placement: @placement) }
      @enrollment.revoke!
      VmResident.release_after_retirement!(placement: @placement)
      assert_not VmResident.held?(@agent)
    end

    test "authenticated known-state recovery releases only its failed hold without verifying snapshot" do
      command = issue
      answer(command, outcome: "unknown", unpaused: false)
      VmResident.status(command:, verifier: Object.new)
      proof = { "command_id" => command.public_id, "container_name" => @agent.container_name,
        "unpaused" => true, "tools_stopped" => false }
      @enrollment.update!(last_facts: { "recovered_backup" => proof })
      VmResident.release_after_recovery!(enrollment: @enrollment)
      assert VmResident.held?(@agent)
      proof["tools_stopped"] = true
      proof["command_id"] = SecureRandom.hex(16)
      @enrollment.update!(last_facts: { "recovered_backup" => proof })
      VmResident.release_after_recovery!(enrollment: @enrollment)
      assert VmResident.held?(@agent)
      proof["command_id"] = command.public_id
      @enrollment.update!(last_facts: { "recovered_backup" => proof })
      VmResident.release_after_recovery!(enrollment: @enrollment)
      assert_not VmResident.held?(@agent)
      assert_equal "failed", VmBackup.find_by!(runner_command: command).state
      assert_not VmBackup.find_by!(runner_command: command).agent_backup_snapshot.ok?
    end

    test "overlapping interaction invalidates a backup" do
      command = issue
      AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", started_at: Time.current, finished_at: Time.current)
      answer(command)
      result = VmResident.status(command:, verifier: Object.new)
      assert_equal "failed", result[:state]
      assert_match(/overlapped/, result[:reason])
    end

    test "graph mutation is refused while checkpoint is held" do
      vault = @agent.create_memory_vault!
      command = issue
      assert VmBackup.find_by!(runner_command: command).checkpoint_digest.present?
      assert_raises(Mnemodyne::Write::Conflict) do
        Mnemodyne::Write.call(vault:, key: "backup-test", operation: "test", payload: {}) { flunk }
      end
    end

    test "async enqueuing refuses an issued hold" do
      issue
      interaction = AgentRuntimeInteraction.create!(agent: @agent, trigger_kind: "wake", started_at: Time.current)
      assert_raises(ResidentTurn::SessionBusy) do
        ResidentTurn.enqueue!(interaction, { session_id: "held" })
      end
    end

  end
end
