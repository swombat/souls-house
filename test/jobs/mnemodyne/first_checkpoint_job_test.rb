require "test_helper"

class Mnemodyne::FirstCheckpointJobTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external")
    @vault = @agent.create_memory_vault!
  end

  test "first attempt is beyond the active window" do
    freeze_time do
      assert_equal 13.minutes.from_now, Mnemodyne::FirstCheckpointJob.next_attempt_at(@agent)
    end
  end

  test "a busy resident defers without starting backup or consuming error retries" do
    @agent.agent_runtime_interactions.create!(trigger_kind: "synthetic", started_at: Time.current)
    Agents::Config.stub(:backups_enabled?, true) do
      Backup::AgentResticJob.stub(:perform_now, ->(*) { flunk "Busy resident must not begin backup" }) do
        freeze_time do
          assert_enqueued_with(job: Mnemodyne::FirstCheckpointJob, args: [ @agent.id ], at: 13.minutes.from_now) do
            assert_no_difference "AgentBackupSnapshot.count" do
              Mnemodyne::FirstCheckpointJob.perform_now(@agent.id)
            end
          end
        end
      end
    end
  end

  test "busy race defers without creating a failed snapshot" do
    Agents::Config.stub(:backups_enabled?, true) do
      Backup::AgentResticJob.stub(:perform_now, ->(*) { raise Backup::AgentRestic::ResidentBusy }) do
        assert_enqueued_with(job: Mnemodyne::FirstCheckpointJob, args: [ @agent.id ]) do
          Mnemodyne::FirstCheckpointJob.perform_now(@agent.id)
        end
      end
    end
  end

  test "backup job busy preflight is not a failed backup" do
    @agent.agent_runtime_interactions.create!(trigger_kind: "synthetic", started_at: Time.current)
    assert_no_difference "AgentBackupSnapshot.count" do
      assert_raises(Backup::AgentRestic::ResidentBusy) do
        Backup::AgentResticJob.perform_now(@agent.id, force: true)
      end
    end
  end

  test "successful checkpoint satisfies pending first checkpoint" do
    @agent.agent_backup_snapshots.create!(restic_snapshot_id: "synthetic", taken_at: Time.current,
      graph_checkpoint_digest: "synthetic", ok: true)
    Agents::Config.stub(:backups_enabled?, true) do
      Backup::AgentResticJob.stub(:perform_now, ->(*) { flunk "Already checkpointed" }) do
        assert_no_enqueued_jobs { Mnemodyne::FirstCheckpointJob.perform_now(@agent.id) }
      end
    end
  end

  test "real failure exhausts visibly after longer retries" do
    reports = []
    job = Mnemodyne::FirstCheckpointJob.new(@agent.id)
    job.executions = 12
    job.exception_executions = { "[StandardError]" => 11 }
    Agents::Config.stub(:backups_enabled?, true) do
      Backup::AgentResticJob.stub(:perform_now, ->(*) { raise Backup::GraphCheckpoint::Error, "synthetic failure" }) do
        Rails.error.stub(:report, ->(error, **options) { reports << options }) do
          assert_raises(Backup::GraphCheckpoint::Error) { job.perform_now }
        end
      end
    end
    assert_equal false, reports.first[:handled]
  end

end
