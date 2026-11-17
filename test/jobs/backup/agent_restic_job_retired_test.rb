require "test_helper"

module Backup
  # Residents 33-38, 46 and 48 (test servers, switched off, servers retired)
  # each got a failed backup row every night until 17 Nov 2026.
  class AgentResticJobRetiredTest < ActiveJob::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.update_columns(uuid: SecureRandom.uuid)
    end

    def job_that_must_not_start
      job = AgentResticJob.new
      job.define_singleton_method(:init_restic_repo!) { |_agent| raise "restic reached" }
      job
    end

    test "a switched-off resident whose server is retired is skipped, with no failed row" do
      @agent.update_columns(runtime: "offline")
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "retired")

      Agents::Config.stub(:backups_enabled?, true) do
        VmResident.stub(:issue!, ->(**) { raise Agents::RemoteRuntime::Unavailable }) do
          assert_nil job_that_must_not_start.perform(@agent.id)
          assert_nil job_that_must_not_start.perform(@agent.id, force: true)
        end
      end
      assert_empty @agent.agent_backup_snapshots
    end

    test "a resident still switched on with a retired server is not skipped: its failure is recorded" do
      @agent.update_columns(runtime: "external")
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "retired")

      Agents::Config.stub(:backups_enabled?, true) do
        VmResident.stub(:issue!, ->(**) { raise Agents::RemoteRuntime::Unavailable }) do
          assert_raises(Agents::RemoteRuntime::Unavailable) { AgentResticJob.new.perform(@agent.id) }
        end
      end
      assert_equal [ "Backup failed: Agents::RemoteRuntime::Unavailable" ], @agent.agent_backup_snapshots.pluck(:stderr_tail)
    end

    test "a switched-off resident whose server is still there is backed up" do
      @agent.update_columns(runtime: "offline")
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
      issued = []

      Agents::Config.stub(:backups_enabled?, true) do
        VmResident.stub(:issue!, ->(placement:) { issued << placement.id }) do
          AgentResticJob.new.perform(@agent.id)
        end
      end
      assert_equal 1, issued.size
    end

    test "the nightly full backup records nothing for a retired resident and still dumps the database" do
      @agent.update_columns(runtime: "offline")
      AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "retired")
      others = Agent.externally_hosted.where.not(uuid: nil).where.not(id: @agent.id)
      others.update_all(uuid: nil)
      dumped = false

      Agents::Config.stub(:backups_enabled?, true) do
        DatabaseBackupJob.stub(:perform_now, -> { dumped = true }) do
          FullBackupJob.perform_now
        end
      end
      assert dumped
      assert_empty @agent.agent_backup_snapshots
    end

  end
end
