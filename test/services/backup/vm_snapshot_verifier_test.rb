require "test_helper"

module Backup
  class VmSnapshotVerifierTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @id = "a" * 64
      payload = { "version" => Mnemodyne::Checkpoint::VERSION, "resident_uuid" => @agent.uuid, "nodes" => [] }
      @digest = Digest::SHA256.hexdigest(JSON.generate(payload))
      @checkpoint = JSON.generate({ "payload" => payload, "sha256" => @digest })
      @file_digest = Digest::SHA256.hexdigest(@checkpoint)
      @snapshots = [ { "id" => @id, "tags" => [ "agent_id=#{@agent.uuid}" ] } ].to_json
    end

    def verify(snapshot_id: @id, checkpoint: @checkpoint, snapshots: @snapshots)
      capture = ->(_agent, command, *) { command == "snapshots" ? snapshots : checkpoint }
      VmSnapshotVerifier.new(capture:).verify!(agent: @agent, snapshot_id:,
        checkpoint_digest: @digest, checkpoint_file_digest: @file_digest)
    end

    test "decrypts tags and exact checkpoint file from house repository" do
      assert verify
    end

    test "snapshot belonging to another resident is not proof" do
      other = [ { "id" => @id, "tags" => [ "agent_id=someone-else" ] } ].to_json
      assert_raises(VmSnapshotVerifier::Invalid) { verify(snapshots: other) }
    end

    test "missing snapshot and altered checkpoint fail" do
      assert_raises(VmSnapshotVerifier::Invalid) { verify(snapshots: "[]") }
      assert_raises(VmSnapshotVerifier::Invalid) { verify(checkpoint: @checkpoint + "\n") }
      assert_raises(VmSnapshotVerifier::Invalid) { verify(snapshot_id: "../config") }
    end

    test "a matching file hash does not excuse a wrong graph digest" do
      capture = ->(_agent, command, *) { command == "snapshots" ? @snapshots : @checkpoint }
      assert_raises(VmSnapshotVerifier::Invalid) do
        VmSnapshotVerifier.new(capture:).verify!(agent: @agent, snapshot_id: @id,
          checkpoint_digest: "b" * 64, checkpoint_file_digest: @file_digest)
      end
    end

    test "normal tests cannot look up production credentials or run docker" do
      assert_raises(VmSnapshotVerifier::Invalid) do
        VmSnapshotVerifier.new.verify!(agent: @agent, snapshot_id: @id,
          checkpoint_digest: @digest, checkpoint_file_digest: @file_digest)
      end
    end

  end
end
