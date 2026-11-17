require "test_helper"

class FullBackupJobTest < ActiveJob::TestCase

  setup do
    @agent_a = agents(:research_assistant)
    @agent_b = agents(:code_reviewer)
    [ @agent_a, @agent_b ].each do |agent|
      agent.update_columns(runtime: "external", uuid: SecureRandom.uuid)
    end
    @dumped = false
    @dump_stub = -> { @dumped = true }
  end

  test "nightly run backs up remaining agents and still dumps the database when one agent fails" do
    attempted = []
    backup_stub = ->(agent_id, force:) do
      attempted << agent_id
      raise "restic backup failed" if agent_id == @agent_a.id
    end

    Backup::AgentResticJob.stub(:perform_now, backup_stub) do
      DatabaseBackupJob.stub(:perform_now, @dump_stub) do
        FullBackupJob.perform_now
      end
    end

    assert_includes attempted, @agent_a.id
    assert_includes attempted, @agent_b.id
    assert @dumped, "database dump should still run after an agent failure in nightly mode"
    assert_enqueued_jobs 1, only: Backup::CommsTelegramDumpJob
  end

  test "fail_fast run aborts before the database dump when an agent backup fails" do
    backup_stub = ->(agent_id, force:) do
      raise "restic backup failed" if agent_id == @agent_a.id
    end

    Backup::AgentResticJob.stub(:perform_now, backup_stub) do
      DatabaseBackupJob.stub(:perform_now, @dump_stub) do
        assert_raises(RuntimeError) { FullBackupJob.perform_now(fail_fast: true) }
      end
    end

    refute @dumped, "database dump must not run after an agent failure in fail_fast mode"
  end

  test "fail_fast run forces agent backups; nightly run respects the backups_enabled gate" do
    forced_flags = []
    backup_stub = ->(_agent_id, force:) { forced_flags << force }

    Backup::AgentResticJob.stub(:perform_now, backup_stub) do
      DatabaseBackupJob.stub(:perform_now, @dump_stub) do
        FullBackupJob.perform_now(fail_fast: true)
        FullBackupJob.perform_now
      end
    end

    assert_equal [ true, true, false, false ], forced_flags
  end

  test "skips agents without a uuid and non-hosted agents" do
    @agent_b.update_columns(uuid: nil)
    attempted = []
    backup_stub = ->(agent_id, force:) { attempted << agent_id }

    Backup::AgentResticJob.stub(:perform_now, backup_stub) do
      DatabaseBackupJob.stub(:perform_now, @dump_stub) do
        FullBackupJob.perform_now
      end
    end

    assert_equal [ @agent_a.id ], attempted
    assert @dumped
  end

  test "a restarted nightly run skips residents already backed up since it was queued, and still dumps the database" do
    queued_at = 30.minutes.ago
    AgentBackupSnapshot.create!(agent: @agent_a, restic_snapshot_id: "done", taken_at: 10.minutes.ago, ok: true)
    AgentBackupSnapshot.create!(agent: @agent_b, restic_snapshot_id: "failed", taken_at: 10.minutes.ago, ok: false)
    AgentBackupSnapshot.create!(agent: @agent_b, restic_snapshot_id: "yesterday", taken_at: 1.day.ago, ok: true)
    attempted = []
    backup_stub = ->(agent_id, force:) { attempted << agent_id }

    Backup::AgentResticJob.stub(:perform_now, backup_stub) do
      DatabaseBackupJob.stub(:perform_now, @dump_stub) do
        job = FullBackupJob.new
        job.enqueued_at = queued_at
        job.perform_now
      end
    end

    assert_not_includes attempted, @agent_a.id
    assert_includes attempted, @agent_b.id
    assert @dumped
  end

  test "a run by hand skips nobody, whatever was backed up a moment ago" do
    AgentBackupSnapshot.create!(agent: @agent_a, restic_snapshot_id: "done", taken_at: 1.minute.ago, ok: true)
    attempted = []
    backup_stub = ->(agent_id, force:) { attempted << agent_id }

    Backup::AgentResticJob.stub(:perform_now, backup_stub) do
      DatabaseBackupJob.stub(:perform_now, @dump_stub) do
        FullBackupJob.perform_now
        job = FullBackupJob.new(fail_fast: true)
        job.enqueued_at = 30.minutes.ago
        job.perform_now
      end
    end

    assert_equal 2, attempted.count(@agent_a.id)
  end

end
