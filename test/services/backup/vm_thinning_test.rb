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

      assert_equal %w[unlock snapshots forget snapshots], calls.map(&:first)
      assert_equal [ "forget", "--keep-daily", "7", "--keep-weekly", "4", "--keep-monthly", "12", "--prune" ], calls[2]
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

    test "the job records a failure on the newest good snapshot and does not raise" do
      good = AgentBackupSnapshot.create!(agent: @agent, restic_snapshot_id: "a" * 64, taken_at: Time.current, ok: true)
      failing = Object.new
      def failing.call(_agent) = raise(VmThinning::Failed, "restic forget failed: repository is locked")

      Agents::Config.stub(:backups_enabled?, true) do
        assert_nil VmThinningJob.perform_now(@agent.id, thinning: failing)
      end
      assert_equal "Prune failed: restic forget failed: repository is locked", good.reload.stderr_tail
      assert good.ok?
    end

    test "the job leaves a resident alone while a backup is in flight" do
      called = false
      thinning = Object.new
      thinning.define_singleton_method(:call) { |_agent| called = true }

      Agents::Config.stub(:backups_enabled?, true) do
        VmResident.stub(:held?, true) { VmThinningJob.perform_now(@agent.id, thinning:) }
      end
      assert_not called
    end

  end
end
