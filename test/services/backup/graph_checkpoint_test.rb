require "test_helper"

class Backup::GraphCheckpointTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", uuid: SecureRandom.uuid)
    @vault = @agent.create_memory_vault!
    @vault.nodes.create!(node_type: "memory", content: "Synthetic backup handle")
  end

  test "secondary instance guard runs before any Docker command" do
    Open3.stub(:capture3, ->(*) { flunk "Docker must not run" }) do
      assert_raises(ArgumentError) { Backup::GraphCheckpoint.with_volume(@agent) { flunk "Must not yield" } }
    end
  end

  test "carrier copies a private checkpoint and is removed even when backup fails" do
    container = "a" * 64
    commands = []
    capture = lambda do |*command|
      commands << command
      if command[1] == "cp"
        assert_equal 0o600, File.stat(command[2]).mode & 0o777
        envelope = JSON.parse(File.read(command[2]))
        assert_equal @agent.uuid, envelope.dig("payload", "resident_uuid")
      end
      [ command[1] == "create" ? container : "", "", Struct.new(:success?).new(true) ]
    end
    Backup::AgentRestic.stub(:docker_environment, []) do
      Open3.stub(:capture3, capture) do
        assert_raises(RuntimeError) do
          Backup::GraphCheckpoint.with_volume(@agent) do |mounts, envelope|
            assert_equal [ "--volumes-from", "#{container}:ro" ], mounts
            assert envelope["sha256"].present?
            raise "Synthetic failure"
          end
        end
      end
    end
    assert_equal [ "docker", "rm", "-v", container ], commands.last
    assert_equal %w[create cp rm], commands.map { |command| command[1] }
  end

  test "read verifies stored digest owner and shape" do
    envelope = Mnemodyne::Checkpoint.export(@vault)
    snapshot = Struct.new(:restic_snapshot_id, :graph_checkpoint_digest).new("synthetic", envelope["sha256"])
    Backup::AgentRestic.stub(:docker_environment, []) do
      [ envelope.to_json, "[]", envelope.deep_merge("payload" => { "resident_uuid" => "foreign" }).to_json ].each_with_index do |body, index|
        Open3.stub(:capture3, [ body, "", Struct.new(:success?).new(true) ]) do
          if index.zero?
            assert_equal envelope, Backup::GraphCheckpoint.read(@agent, snapshot)
          else
            assert_raises(Backup::GraphCheckpoint::Error) { Backup::GraphCheckpoint.read(@agent, snapshot) }
          end
        end
      end
    end
  end

  test "restic backup receives graph mounts but init does not" do
    job = Backup::AgentResticJob.new
    commands = []
    Backup::AgentRestic.stub(:backup_mounts, []) do
      Backup::AgentRestic.stub(:docker_environment, []) do
        Open3.stub(:capture3, ->(*command) { commands << command; [ "", "", Struct.new(:success?).new(true) ] }) do
          job.send(:init_restic_repo!, @agent)
          job.send(:run_restic_backup, @agent, graph_mounts: [ "--volumes-from", "synthetic:ro" ])
        end
      end
    end
    assert_not_includes commands.first, "--volumes-from"
    assert_includes commands.last, "synthetic:ro"
  end

end
