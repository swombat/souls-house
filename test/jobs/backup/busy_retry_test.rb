require "test_helper"

module Backup
  # #1029: a resident found busy by the nightly backup was skipped with no row
  # and no retry (Lume, 18 Nov 2026).
  class BusyRetryTest < ActiveJob::TestCase

    setup do
      @agent = agents(:research_assistant)
      @other = agents(:code_reviewer)
      [ @agent, @other ].each { |agent| agent.update_columns(runtime: "external", uuid: SecureRandom.uuid) }
      @busy = AgentRestic::ResidentBusy.new("Backup requires an idle resident")
    end

    def nightly(enqueued_at: nil)
      attempted = []
      stub = ->(agent_id, force:) do
        attempted << agent_id
        raise @busy if agent_id == @agent.id
      end
      AgentResticJob.stub(:perform_now, stub) do
        DatabaseBackupJob.stub(:perform_now, -> { @dumped = true }) do
          job = FullBackupJob.new
          job.enqueued_at = enqueued_at
          job.perform_now
        end
      end
      attempted
    end

    def skips(agent) = agent.agent_backup_snapshots.where("stderr_tail LIKE ?", "#{BusyRetry::PREFIX}%").order(:id)

    def queued_job_ids
      enqueued_jobs.select { |job| job["job_class"] == "Backup::AgentResticJob" }.map { |job| job["job_id"] }
    end

    def queued_attempts
      enqueued_jobs.select { |job| job["job_class"] == "Backup::AgentResticJob" }
        .map { |job| job["arguments"].last["busy_attempt"] }
    end

    # Runs the retry job against a VM resident whose issue! answers with block.
    def retry!(attempt, &issue)
      Agents::Config.stub(:backups_enabled?, true) do
        Agents::RemoteRuntime.stub(:remote?, true) do
          Agents::RemoteRuntime.stub(:placement_for, Object.new) do
            VmResident.stub(:issue!, issue) do
              AgentResticJob.new.perform(@agent.id, busy_attempt: attempt)
            end
          end
        end
      end
    end

    test "a busy resident in the nightly run gets a row saying so and a later try, and the run goes on" do
      attempted = nightly

      assert_includes attempted, @other.id
      assert @dumped
      row = skips(@agent).sole
      refute row.ok, "a skip is never counted as a backup"
      assert_match "attempt 1 of #{BusyRetry::ATTEMPTS}", row.stderr_tail
      assert_match "idle resident", row.stderr_tail
      assert_equal [ 2 ], queued_attempts
      assert_empty skips(@other)
    end

    test "a retry that finds the resident still busy records it and queues the next, up to the last" do
      retry!(2) { |**| raise @busy }
      assert_equal [ 3 ], queued_attempts
      assert_match "attempt 2 of", skips(@agent).last.stderr_tail

      clear_enqueued_jobs
      retry!(BusyRetry::ATTEMPTS) { |**| raise @busy }
      assert_empty queued_attempts, "the last try queues nothing"
      assert_match "no more tries tonight", skips(@agent).last.stderr_tail
    end

    test "a retry issues the backup once the resident is idle" do
      issued = 0
      retry!(2) { |**| issued += 1 }
      assert_equal 1, issued
      assert_empty skips(@agent)
      assert_empty queued_attempts
    end

    test "a retry stands down when the resident was backed up after the busy attempt" do
      AgentBackupSnapshot.create!(agent: @agent, restic_snapshot_id: "caught-up", taken_at: 5.minutes.ago, ok: true)
      retry!(3) { |**| flunk "a caught-up resident is not backed up again" }
      assert_empty queued_attempts
    end

    test "a restarted nightly run does not start a second chain while the retry is still queued" do
      queued_at = 30.minutes.ago
      nightly(enqueued_at: queued_at)
      job_id = queued_job_ids.sole
      assert_match "[retry job #{job_id}]", skips(@agent).sole.stderr_tail
      clear_enqueued_jobs
      attempted = BusyRetry.stub(:retry_pending?, ->(id) { id == job_id }) { nightly(enqueued_at: queued_at) }

      assert_not_includes attempted, @agent.id
      assert_equal 1, skips(@agent).count
      assert_empty queued_attempts
    end

    test "a skip row whose retry was lost does not stop a restarted run (#1036)" do
      queued_at = 30.minutes.ago
      nightly(enqueued_at: queued_at)
      clear_enqueued_jobs
      # The retry job is gone (interrupted, deleted, failed): nothing is owed.
      attempted = BusyRetry.stub(:retry_pending?, false) { nightly(enqueued_at: queued_at) }

      assert_includes attempted, @agent.id
      assert_equal [ 2 ], queued_attempts
    end

    test "when the queue refuses the retry, the row says so and a restart tries again (#1036)" do
      queued_at = 30.minutes.ago
      AgentResticJob.stub(:set, ->(**) { raise ActiveJob::EnqueueError, "queue down" }) do
        nightly(enqueued_at: queued_at)
      end
      row = skips(@agent).sole
      assert_match "could not be queued", row.stderr_tail
      assert_no_match "retry job", row.stderr_tail
      assert_empty queued_attempts

      attempted = BusyRetry.stub(:retry_pending?, ->(_) { flunk "no job to look for" }) { nightly(enqueued_at: queued_at) }
      assert_includes attempted, @agent.id
      assert_equal [ 2 ], queued_attempts
    end

    test "a restart after the last try does not start the night over" do
      queued_at = 3.hours.ago
      AgentBackupSnapshot.create!(agent: @agent, restic_snapshot_id: "unknown", taken_at: 10.minutes.ago, ok: false,
        stderr_tail: "#{BusyRetry::PREFIX} (x); attempt 6 of 6, #{BusyRetry::LAST}")
      attempted = nightly(enqueued_at: queued_at)
      assert_not_includes attempted, @agent.id
    end

    test "a run by hand still fails on a busy resident rather than deferring" do
      stub = ->(agent_id, force:) { raise @busy if agent_id == @agent.id }
      AgentResticJob.stub(:perform_now, stub) do
        DatabaseBackupJob.stub(:perform_now, -> { flunk "no dump over an incomplete set" }) do
          assert_raises(AgentRestic::ResidentBusy) { FullBackupJob.perform_now(fail_fast: true) }
        end
      end
      assert_empty skips(@agent)
    end

    test "a first attempt queued outside the nightly run still raises when busy" do
      Agents::Config.stub(:backups_enabled?, true) do
        Agents::RemoteRuntime.stub(:remote?, true) do
          Agents::RemoteRuntime.stub(:placement_for, Object.new) do
            VmResident.stub(:issue!, ->(**) { raise @busy }) do
              assert_raises(AgentRestic::ResidentBusy) { AgentResticJob.new.perform(@agent.id) }
            end
          end
        end
      end
    end

  end
end
