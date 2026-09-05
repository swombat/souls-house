require "test_helper"

class Backup::GraphRestoreTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", uuid: SecureRandom.uuid)
    @vault = @agent.create_memory_vault!
    @vault.nodes.create!(node_type: "memory", content: "Synthetic restore handle")
    @envelope = Mnemodyne::Checkpoint.export(@vault)
    @snapshot = @agent.agent_backup_snapshots.create!(restic_snapshot_id: "synthetic", taken_at: Time.current, ok: true,
      graph_checkpoint_digest: @envelope["sha256"], graph_schema_version: 1)
    @restore = Backup::AgentResticRestore.new(@agent)
  end

  test "unpaired backup is refused before any destructive work" do
    @snapshot.update!(graph_checkpoint_digest: nil)
    with_fake_runtime do |events|
      assert_raises(Backup::AgentResticRestore::RestoreError) { @restore.restore! }
      assert_empty events
    end
  end

  test "failed graph import leaves resident suspended and never wakes" do
    with_fake_runtime do |events|
      Mnemodyne::Checkpoint.stub(:import, ->(*) { raise Mnemodyne::Checkpoint::Invalid }) do
        assert_raises(Mnemodyne::Checkpoint::Invalid) { @restore.restore! }
      end
      assert_equal %i[remove volumes restore], events
      assert @vault.reload.suspended_at?
    end
  end

  test "valid graph imports before wake and invalidates old receipts" do
    with_fake_runtime do |events|
      @restore.restore!
      assert_equal %i[remove volumes restore configure wake], events
      assert_not @vault.reload.suspended_at?
      assert_equal 1, @vault.recall_generation
      assert_equal "Synthetic restore handle", @vault.nodes.first.content
    end
  end

  test "suspended graph also blocks later scheduled runtime access and respawn" do
    @vault.update!(suspended_at: Time.current)
    sandbox = Agents::Sandbox.new(@agent)
    assert_raises(Agents::Sandbox::SandboxError) { sandbox.spawn! }
    assert_raises(Agents::Sandbox::SandboxError) { sandbox.start! }
    assert_raises(Agents::Sandbox::SandboxError) { sandbox.with_runtime { flunk "Must not invoke resident" } }
  end

  private

  # Every side effect is stubbed. No Docker calls, real credentials, guard
  # bypass outside this synthetic test, or resident provisioning is performed.
  def with_fake_runtime
    events = []
    resources = Object.new
    resources.define_singleton_method(:verify_existing!) { true }
    sandbox = Object.new
    sandbox.define_singleton_method(:spawn!) { events << :wake }
    @restore.define_singleton_method(:remove_container!) { events << :remove }
    @restore.define_singleton_method(:recreate_volumes!) { events << :volumes }
    @restore.define_singleton_method(:restore_snapshot!) { |_| events << :restore }
    @restore.define_singleton_method(:configure_for_local_runtime!) { events << :configure }
    LocalInstance.stub(:current, Struct.new(:namespace).new(nil)) do
      Agents::Resources.stub(:new, resources) do
        Agents::Sandbox.stub(:new, sandbox) do
          Backup::GraphCheckpoint.stub(:read, @envelope) { yield events }
        end
      end
    end
  end

end
