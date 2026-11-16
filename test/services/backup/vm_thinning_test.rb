require "test_helper"

module Backup
  class VmThinningTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
      @agent.update!(restic_password: "synthetic-restic-password", uuid: SecureRandom.uuid)
      @placement = AgentPlacement.create!(agent: @agent, backend: "hetzner_cloud", state: "ready", provider_server_id: 4242)
    end

    def snapshot(days_ago) = { "id" => SecureRandom.hex(32), "time" => days_ago.days.ago.iso8601 }

    # A stand-in for restic: records each call, and forget drops `forgets` snapshots.
    def restic(list, forgets: 0, calls: [])
      lambda do |_agent, *args|
        calls << args
        case args.first
        when "snapshots" then JSON.generate(list)
        when "stats" then JSON.generate("total_size" => 1.gigabyte)
        when "forget" then list.shift(forgets) && ""
        else ""
        end
      end
    end

    test "thins to the resident's keep rules and reports what is left" do
      calls = []
      list = [ snapshot(40), snapshot(2), snapshot(1) ]
      result = VmThinning.new(run: restic(list, forgets: 1, calls:)).call(@agent)

      assert_equal %w[snapshots forget prune snapshots snapshots stats], calls.map(&:first)
      assert_equal [ "forget", "--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "12" ], calls[1]
      assert_equal 2, result.kept
      assert_equal 1, result.removed
      assert_in_delta 2.days.ago, Time.zone.parse(result.oldest_at), 5
      assert_equal 2, @agent.reload.backup_history["snapshots"]
    end

    test "a thinning that leaves nothing is a failure, never a success" do
      list = [ snapshot(1) ]
      assert_raises(VmThinning::Failed) { VmThinning.new(run: restic(list, forgets: 1)).call(@agent) }
    end

    test "a house resident is never thinned this way" do
      @placement.destroy!
      calls = []
      assert_raises(VmThinning::Failed) { VmThinning.new(run: restic([], calls:)).call(@agent.reload) }
      assert_empty calls
    end

    # A stand-in for VmThinning in the job: records what it was asked to do.
    def thinning(fail_with: nil, log: [])
      double = Object.new
      double.define_singleton_method(:call) do |_agent, renew: nil|
        log << :call
        raise VmThinning::Failed, fail_with if fail_with

        VmThinning::Result.new(kept: 3, removed: 1, oldest_at: nil)
      end
      double.define_singleton_method(:recover) { |_agent, renew: nil| log << :recover }
      double
    end

    def run_job(double)
      Agents::Config.stub(:backups_enabled?, true) { VmThinningJob.perform_now(@agent.id, thinning: double) }
    end

    test "the job marks the resident while it thins and clears the mark after" do
      seen = nil
      double = thinning
      double.define_singleton_method(:call) do |agent, renew: nil|
        seen = agent.reload.backup_thinning_started_at
        VmThinning::Result.new(kept: 1, removed: 0, oldest_at: nil)
      end
      run_job(double)

      assert seen.present?
      assert_nil @agent.reload.backup_thinning_started_at
    end

    test "a failed thinning is recorded, recovered, and does not raise" do
      good = AgentBackupSnapshot.create!(agent: @agent, restic_snapshot_id: "a" * 64, taken_at: Time.current, ok: true)
      log = []
      assert_nil run_job(thinning(fail_with: "restic forget failed: timed out", log:))

      assert_equal %i[call recover], log
      assert_equal "Prune failed: restic forget failed: timed out", good.reload.stderr_tail
      assert good.ok?
      assert_nil @agent.reload.backup_thinning_started_at
    end

    test "when recovery itself fails the mark stays, so no backup is issued into a locked repository" do
      double = thinning(fail_with: "killed")
      double.define_singleton_method(:recover) { |_agent, renew: nil| raise VmThinning::Failed, "restic unlock failed" }
      run_job(double)

      assert @agent.reload.backup_thinning_started_at.present?
    end

    test "the job does not start while a backup is held or another thinning is running" do
      log = []
      VmResident.stub(:held?, true) { run_job(thinning(log:)) }
      @agent.update!(backup_thinning_started_at: 1.minute.ago)
      run_job(thinning(log:))

      assert_empty log
      assert @agent.reload.backup_thinning_started_at.present?, "another job's mark is left alone"
    end

    test "a mark left by a dead job is taken over: recover first, then thin" do
      @agent.update!(backup_thinning_started_at: 2.hours.ago)
      log = []
      run_job(thinning(log:))

      assert_equal %i[recover call], log
      assert_nil @agent.reload.backup_thinning_started_at
    end

    test "the mark is renewed before every restic command, and a thinning that lost it stops there" do
      calls = []
      renewals = 0
      VmThinning.new(run: restic([ snapshot(1) ], calls:)).call(@agent, renew: -> { renewals += 1 })
      assert_equal calls.size, renewals

      calls.clear
      lost = -> { raise VmThinningJob::Lease::Lost, "taken" }
      assert_raises(VmThinningJob::Lease::Lost) { VmThinning.new(run: restic([ snapshot(1) ], calls:)).call(@agent, renew: lost) }
      assert_empty calls
    end

    test "a job that renews before each command keeps the mark however long the whole job runs" do
      double = thinning
      agent = @agent
      clock = self
      double.define_singleton_method(:call) do |_agent, renew: nil|
        3.times do
          clock.travel 25.minutes
          renew.call
          raise "the mark expired under a live job" unless VmThinning.running?(agent.reload)
        end
        VmThinning::Result.new(kept: 1, removed: 0, oldest_at: nil)
      end
      assert_equal 1, run_job(double).kept
      assert_nil @agent.reload.backup_thinning_started_at
    end

    test "an unexpected error keeps the mark unless recovery completes" do
      log = []
      double = thinning(log:)
      double.define_singleton_method(:call) { |_agent, renew: nil| raise IOError, "closed stream" }
      assert_nil run_job(double)
      assert_equal %i[recover], log
      assert_nil @agent.reload.backup_thinning_started_at

      double.define_singleton_method(:recover) { |_agent, renew: nil| raise IOError, "closed stream" }
      run_job(double)
      assert @agent.reload.backup_thinning_started_at.present?
    end

    test "a job whose mark was taken over recovers nothing and clears nothing" do
      log = []
      replacement_mark = 1.minute.from_now.change(usec: 0)
      agent = @agent
      old = thinning(log:)
      old.define_singleton_method(:call) do |_agent, renew: nil|
        # Another job took the mark over while this one was stalled.
        agent.update_columns(backup_thinning_started_at: replacement_mark)
        raise VmThinning::Failed, "restic forget failed: killed"
      end
      run_job(old)
      assert_empty log, "the old job must not recover a repository it no longer owns"
      assert_equal replacement_mark, @agent.reload.backup_thinning_started_at

      # And the same once the replacement has finished and cleared the mark.
      old.define_singleton_method(:call) do |_agent, renew: nil|
        agent.update_columns(backup_thinning_started_at: nil)
        raise VmThinning::Failed, "restic forget failed: killed"
      end
      @agent.update_columns(backup_thinning_started_at: nil)
      run_job(old)
      assert_empty log
      assert_nil @agent.reload.backup_thinning_started_at
    end

    test "recover clears every lock in the repository" do
      calls = []
      VmThinning.new(run: restic([], calls:)).recover(@agent)
      assert_equal [ [ "unlock", "--remove-all" ] ], calls
    end

    # A stand-in for the Docker client: `ps` answers with `listed` and `ok`.
    def docker(listed: "", ok: true, calls: [])
      lambda do |*args|
        calls << args
        args.first == "ps" ? [ listed, ok ] : [ "", true ]
      end
    end

    test "recovery unlocks only after Docker lists no container of that name, stopped ones included" do
      calls = []
      restic_calls = []
      VmThinning.new(run: restic([], calls: restic_calls), docker: docker(calls:)).recover(@agent)

      name = "vm-backup-thin-#{@agent.uuid}"
      assert_equal [ [ "rm", "--force", name ], [ "ps", "--all", "--filter", "name=#{name}", "--format", "{{.Names}}" ] ], calls
      assert_equal [ [ "unlock", "--remove-all" ] ], restic_calls
    end

    test "a Docker error is unknown, not gone: no unlock" do
      restic_calls = []
      thinning = VmThinning.new(run: restic([], calls: restic_calls), docker: docker(ok: false))
      assert_raises(VmThinning::Failed) { thinning.recover(@agent) }
      assert_empty restic_calls
    end

    test "a container still listed, running or stopped, means no unlock" do
      restic_calls = []
      name = "vm-backup-thin-#{@agent.uuid}"
      thinning = VmThinning.new(run: restic([], calls: restic_calls), docker: docker(listed: "#{name}\n"))
      assert_raises(VmThinning::Failed) { thinning.recover(@agent) }
      assert_empty restic_calls

      # A longer name that only contains this one is another container.
      VmThinning.new(run: restic([], calls: restic_calls), docker: docker(listed: "#{name}-old\n")).recover(@agent)
      assert_equal [ [ "unlock", "--remove-all" ] ], restic_calls
    end

    test "recovery renews before each step and stops before the unlock once the lease is lost" do
      steps = []
      docker_calls = []
      restic_calls = []
      thinning = VmThinning.new(run: restic([], calls: restic_calls), docker: docker(calls: docker_calls))
      thinning.recover(@agent, renew: -> { steps << :renew })
      assert_equal 3, steps.size, "before the removal, the check and the unlock"

      docker_calls.clear
      restic_calls.clear
      renewals = 0
      lost = -> { (renewals += 1) > 2 ? raise(VmThinningJob::Lease::Lost, "taken over") : nil }
      assert_raises(VmThinningJob::Lease::Lost) { thinning.recover(@agent, renew: lost) }
      assert_equal %w[rm ps], docker_calls.map(&:first)
      assert_empty restic_calls
    end

    test "the kill grace is inside the lease" do
      assert_operator VmThinning::TIMEOUT_SECONDS + VmThinning::KILL_GRACE_SECONDS, :<, VmThinning::CLAIM_SECONDS
      assert_operator VmThinning::RECOVERY_TIMEOUT_SECONDS + VmThinning::KILL_GRACE_SECONDS, :<, VmThinning::CLAIM_SECONDS
    end

    test "the interruption is timed from the first one and ends only when the mark is released" do
      abandoned = 2.hours.ago.change(usec: 0)
      @agent.update_columns(backup_thinning_started_at: abandoned)
      double = thinning
      double.define_singleton_method(:recover) { |_agent, renew: nil| raise VmThinning::Failed, "unknown" }
      run_job(double)
      assert_equal abandoned, @agent.reload.backup_thinning_interrupted_at
      assert @agent.backup_thinning_started_at.present?

      # A later failed takeover moves the lease, never the interruption.
      @agent.update_columns(backup_thinning_started_at: 1.hour.ago.change(usec: 0))
      run_job(double)
      assert_equal abandoned, @agent.reload.backup_thinning_interrupted_at

      @agent.update_columns(backup_thinning_started_at: 1.hour.ago.change(usec: 0))
      run_job(thinning)
      assert_nil @agent.reload.backup_thinning_started_at
      assert_nil @agent.backup_thinning_interrupted_at
    end

    test "a recovery that fails straight after a failed thinning starts the interruption" do
      double = thinning(fail_with: "restic forget failed")
      double.define_singleton_method(:recover) { |_agent, renew: nil| raise VmThinning::Failed, "unknown" }
      freeze_time do
        run_job(double)
        assert_equal Time.current, @agent.reload.backup_thinning_interrupted_at
      end
    end

    test "the recovery job reports a resident whose backups have been paused for three hours, and not before" do
      @agent.update!(runtime: "external", backup_thinning_started_at: 10.minutes.ago, backup_thinning_interrupted_at: 2.hours.ago)
      reported = []
      report = ->(error, **) { reported << error }
      Agents::Config.stub(:backups_enabled?, true) do
        Rails.error.stub(:report, report) { VmThinningRecoveryJob.perform_now }
        assert_empty reported

        @agent.update!(backup_thinning_interrupted_at: 181.minutes.ago)
        Rails.error.stub(:report, report) { VmThinningRecoveryJob.perform_now }
      end
      assert_equal 1, reported.size
      assert_kind_of VmThinning::Stalled, reported.first
      assert_includes reported.first.message, @agent.name
    end

    test "the recovery job sends an abandoned mark back to thinning, and leaves a live mark and a held backup alone" do
      Agents::Config.stub(:backups_enabled?, true) do
        @agent.update!(runtime: "external", backup_thinning_started_at: 10.minutes.ago)
        assert_no_enqueued_jobs(only: VmThinningJob) { VmThinningRecoveryJob.perform_now }

        @agent.update!(backup_thinning_started_at: 2.hours.ago)
        assert_enqueued_with(job: VmThinningJob, args: [ @agent.id ]) { VmThinningRecoveryJob.perform_now }

        VmResident.stub(:held?, true) do
          assert_no_enqueued_jobs(only: VmThinningJob) { VmThinningRecoveryJob.perform_now }
        end
      end
    end

    test "the recovery job does nothing when backups are switched off" do
      @agent.update!(runtime: "external", backup_thinning_started_at: 2.hours.ago)
      Agents::Config.stub(:backups_enabled?, false) do
        assert_no_enqueued_jobs { VmThinningRecoveryJob.perform_now }
      end
    end

    # The recovery was written and tested in a job that nothing ran. What the
    # design depends on is the schedule entry, so that is tested too.
    test "the recovery job is on the production schedule, more often than a mark takes to be abandoned" do
      entry = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true).dig("production", "vm_thinning_recovery")
      assert_equal "Backup::VmThinningRecoveryJob", entry["class"]
      assert_equal "every 10 minutes", entry["schedule"]
      assert_operator 10.minutes, :<, VmThinning::CLAIM_SECONDS
    end

    test "the sweeper issues no backup while any mark stands" do
      @agent.update!(runtime: "external", backup_thinning_started_at: 2.hours.ago)
      Agents::Config.stub(:backups_enabled?, true) do
        AgentBackupSweeperJob.perform_now
        backups = enqueued_jobs.select { |job| job["job_class"] == "Backup::AgentResticJob" }
        assert backups.none? { |job| job["arguments"].first == @agent.id }
        @agent.update!(backup_thinning_started_at: nil)
        assert_enqueued_with(job: AgentResticJob, args: [ @agent.id ]) { AgentBackupSweeperJob.perform_now }
      end
    end

  end
end
