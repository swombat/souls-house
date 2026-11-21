require "test_helper"

module Backup
  # A claim only helps if a worker that dies after `docker pause` leaves it
  # behind, so it has to be committed before the pause, not just written
  # first (Mira, #1088). Non-transactional so a second database session can
  # actually see, or fail to see, the row.
  class PauseClaimCommitTest < ActiveSupport::TestCase

    self.use_transactional_tests = false

    setup do
      @agent = agents(:research_assistant)
      PauseClaim.where(agent_id: @agent.id).delete_all
    end

    teardown do
      PauseClaim.where(agent_id: @agent.id).delete_all
      DeployFence.delete_all
    end

    test "fence first: a claim waits on the fence's lock, then is refused" do
      raised, go = Thread::Queue.new, Thread::Queue.new
      deploy = in_session do
        DeployFence.serialized do
          DeployFence.create!(deploy_id: "run-1", raised_at: Time.current, expires_at: 10.minutes.from_now)
          raised << true
          go.pop(timeout: 10)
        end
      end
      assert raised.pop(timeout: 10), "the fence was raised"
      backup = in_session do
        PauseClaim.claim!(@agent, "c" * 64)
        :claimed
      rescue AgentRestic::ResidentBusy
        :refused
      end
      refute backup.join(0.5), "the claim waits on the fence's lock rather than reading past it"
      go << true
      assert deploy.join(10)
      assert backup.join(10)
      assert_equal :refused, backup.value
      assert_nil PauseClaim.find_by(agent_id: @agent.id)
    ensure
      go&.close
      [ deploy, backup ].compact.each { |thread| thread.kill unless thread.join(1) }
    end

    test "claim first: a deploy raising its fence after it sees the committed claim" do
      claimed, go = Thread::Queue.new, Thread::Queue.new
      backup = in_session do
        DeployFence.serialized do
          PauseClaim.where(agent_id: @agent.id).delete_all
          PauseClaim.create!(agent_id: @agent.id, container_id: "c" * 64, token: "t", touched_at: Time.current)
          claimed << true
          go.pop(timeout: 10)
        end
      end
      assert claimed.pop(timeout: 10)
      deploy = in_session do
        DeployFence.raise!("run-1", ttl: 10.minutes)
        PauseClaim.where(agent_id: @agent.id).pluck(:agent_id)
      end
      refute deploy.join(0.5), "the fence waits for the claim's transaction"
      go << true
      assert backup.join(10)
      assert deploy.join(10)
      assert_equal [ @agent.id ], deploy.value, "the deploy's wait sees the claim that won the lock"
    ensure
      go&.close
      [ deploy, backup ].compact.each { |thread| thread.kill unless thread.join(1) }
    end

    test "a claim made inside a caller's transaction is committed on its own, before that transaction ends" do
      seen = nil
      ActiveRecord::Base.transaction do
        PauseClaim.claim!(@agent, "c" * 64)
        seen = in_session { PauseClaim.where(agent_id: @agent.id).exists? }.tap { |t| assert t.join(10) }.value
        raise ActiveRecord::Rollback
      end
      assert seen, "another session sees the claim while the caller's transaction is still open"
      assert PauseClaim.find_by(agent_id: @agent.id), "rolling the caller back doesn't take the claim with it"
    end

    test "inside a caller's transaction, a backup replaces an old claim without waiting on its caller" do
      PauseClaim.create!(agent_id: @agent.id, container_id: "old", token: "old", touched_at: 1.day.ago)
      docker = lambda do |*command|
        case command[1]
        when "inspect" then [ "cid-2 true false", "", ok ]
        when "pause", "unpause" then [ "", "", ok ]
        else flunk "unexpected docker #{command[1]}"
        end
      end
      seen = nil
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            Agents::Resources.stub(:new, verified_resources) do
              Open3.stub(:capture3, docker) do
                AgentRestic.with_quiesced(@agent) do
                  seen = in_session { PauseClaim.where(agent_id: @agent.id).pluck(:container_id) }
                    .tap { |t| t.join(10) }.value
                end
              end
            end
          end
        end
      end
      assert worker.join(20), "the backup finished instead of waiting on itself"
      worker.value
      assert_equal [ "cid-2" ], seen, "the replacement was committed and visible during the pause"
    ensure
      worker&.kill unless worker&.join(1)
    end

    test "the heartbeat touches the claim from its own thread until stopped" do
      token = PauseClaim.claim!(@agent, "c" * 64)
      PauseClaim.where(token:).update_all(touched_at: 1.hour.ago)
      heartbeat = PauseClaim::Heartbeat.start(token, interval: 0.05)
      sleep 0.3
      heartbeat.stop
      touched = PauseClaim.find_by!(token:).touched_at
      assert_operator touched, :>, 1.minute.ago
      sleep 0.2
      assert_equal touched, PauseClaim.find_by!(token:).touched_at, "stopped means stopped"
    ensure
      heartbeat&.stop
    end

    test "the claim is committed and visible to another session before docker pause" do
      seen_at_pause = :not_paused
      docker = lambda do |*command|
        case command[1]
        when "inspect" then [ "cid-1 true false", "", ok ]
        when "pause"
          seen_at_pause = Thread.new do
            ActiveRecord::Base.connection_pool.with_connection do
              PauseClaim.where(agent_id: @agent.id).pluck(:container_id)
            end
          end.value
          [ "", "", ok ]
        when "unpause" then [ "", "", ok ]
        else flunk "unexpected docker #{command[1]}"
        end
      end
      Agents::Resources.stub(:new, verified_resources) do
        Open3.stub(:capture3, docker) do
          assert_equal :done, AgentRestic.with_quiesced(@agent) { :done }
        end
      end
      assert_equal [ "cid-1" ], seen_at_pause
      assert_nil PauseClaim.find_by(agent_id: @agent.id), "released after a clean unpause"
    end

    private

    def in_session(&block)
      Thread.new { ActiveRecord::Base.connection_pool.with_connection(&block) }
    end

    def ok = Struct.new(:success?).new(true)

    def verified_resources
      real = Agents::Resources.new(@agent)
      Object.new.tap do |resources|
        resources.define_singleton_method(:verify_existing!) { |**| true }
        resources.define_singleton_method(:volumes) { real.volumes }
      end
    end

  end
end
