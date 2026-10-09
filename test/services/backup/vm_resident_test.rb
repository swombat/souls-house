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
        "size_bytes" => 42, "duration_ms" => 12
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
