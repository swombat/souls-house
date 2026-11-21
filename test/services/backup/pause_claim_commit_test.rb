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
