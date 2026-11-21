require "test_helper"

module Backup
  class DeployFenceTest < ActiveSupport::TestCase

    setup do
      @agent = agents(:research_assistant)
    end

    test "while a deploy's fence is up a backup can't claim a pause; once lowered or expired it can" do
      DeployFence.raise!("run-1", ttl: 10.minutes)
      assert DeployFence.up?
      assert_raises(AgentRestic::ResidentBusy) { PauseClaim.claim!(@agent, "c" * 64) }
      assert_nil PauseClaim.find_by(agent_id: @agent.id)

      DeployFence.lower!("run-1")
      refute DeployFence.up?
      assert PauseClaim.claim!(@agent, "c" * 64)
      PauseClaim.release!(@agent)

      DeployFence.raise!("run-2", ttl: 10.minutes)
      travel 11.minutes do
        refute DeployFence.up?, "a deploy that died holding its fence only delays backups"
        assert PauseClaim.claim!(@agent, "c" * 64)
      end
    end

    test "a claim records its first heartbeat, and touch! moves it on" do
      token = PauseClaim.claim!(@agent, "c" * 64)
      first = PauseClaim.find_by!(token:).touched_at
      assert first
      travel 2.minutes do
        PauseClaim.touch!(token)
        assert_operator PauseClaim.find_by!(token:).touched_at, :>, first
      end
    end

  end
end
