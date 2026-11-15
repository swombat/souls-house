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
        when "forget" then list.shift(forgets) && ""
        else ""
        end
      end
    end

    test "thins to the resident's keep rules and reports what is left" do
      calls = []
      list = [ snapshot(40), snapshot(2), snapshot(1) ]
      result = VmThinning.new(run: restic(list, forgets: 1, calls:)).call(@agent)

      assert_equal %w[snapshots forget snapshots], calls.map(&:first)
      assert_equal [ "forget", "--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "12", "--prune" ], calls[1]
      assert_equal 2, result.kept
      assert_equal 1, result.removed
      assert_in_delta 2.days.ago, result.oldest_at, 5
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
      double.define_singleton_method(:call) do |_agent|
        log << :call
        raise VmThinning::Failed, fail_with if fail_with

        VmThinning::Result.new(kept: 3, removed: 1, oldest_at: nil)
      end
      double.define_singleton_method(:recover) { |_agent| log << :recover }
      double
    end

    def run_job(double)
      Agents::Config.stub(:backups_enabled?, true) { VmThinningJob.perform_now(@agent.id, thinning: double) }
    end

    test "the job marks the resident while it thins and clears the mark after" do
      seen = nil
      double = thinning
      double.define_singleton_method(:call) do |agent|
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
      double.define_singleton_method(:recover) { |_agent| raise VmThinning::Failed, "restic unlock failed" }
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

    test "recover clears every lock in the repository" do
      calls = []
      VmThinning.new(run: restic([], calls:)).recover(@agent)
      assert_equal [ [ "unlock", "--remove-all" ] ], calls
    end

    test "the sweeper sends an abandoned mark to recovery and issues no backup while any mark stands" do
      @agent.update!(runtime: "external", backup_thinning_started_at: 2.hours.ago)
      Agents::Config.stub(:backups_enabled?, true) do
        assert_enqueued_with(job: VmThinningJob, args: [ @agent.id ]) { AgentBackupSweeperJob.perform_now }
        backups = enqueued_jobs.select { |job| job["job_class"] == "Backup::AgentResticJob" }
        assert backups.none? { |job| job["arguments"].first == @agent.id }
        @agent.update!(backup_thinning_started_at: nil)
        assert_enqueued_with(job: AgentResticJob, args: [ @agent.id ]) { AgentBackupSweeperJob.perform_now }
      end
    end

  end
end
