require "test_helper"

class HostedAgentRuntimeReconcileJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update!(
      runtime: "external",
      uuid: SecureRandom.uuid_v7,
      container_name: "hk-agent-test",
      container_image: "helixkit-agent-runtime:latest",
      health_state: "healthy"
    )
  end

  test "recreates stale hosted sandbox while preserving volumes" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, true)
    sandbox.expect(:active_turn?, false)
    sandbox.expect(:recreate!, true)

    Agents::Sandbox.stub(:new, ->(agent) {
      assert_equal @agent, agent
      sandbox
    }) do
      perform_reconcile
    end

    sandbox.verify
  end

  test "skips current sandbox" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, false)

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      perform_reconcile
    end

    sandbox.verify
    assert true
  end

  test "retries active stale sandbox later" do
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, true)
    sandbox.expect(:active_turn?, true)

    assert_enqueued_with(job: HostedAgentRuntimeReconcileJob, args: [ @agent.id ]) do
      Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
        perform_reconcile
      end
    end

    sandbox.verify
  end

  test "returns a pinned managed runtime to the latest channel before reconciling" do
    @agent.update!(container_image: "helixkit-agent-runtime:canary-fix")
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, true)
    sandbox.expect(:active_turn?, false)
    sandbox.expect(:recreate!, true)

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      perform_reconcile
    end

    sandbox.verify
    assert_equal "helixkit-agent-runtime:latest", @agent.reload.container_image
  end

  test "preserves a deliberately custom runtime image" do
    @agent.update!(container_image: "example.com/resident/custom-runtime:v2")
    sandbox = Minitest::Mock.new
    sandbox.expect(:stale_container?, false)

    Agents::Sandbox.stub(:new, ->(_agent) { sandbox }) do
      perform_reconcile
    end

    sandbox.verify
    assert_equal "example.com/resident/custom-runtime:v2", @agent.reload.container_image
  end

  private

  def perform_reconcile
    Agents::Config.stub(:default_image, "helixkit-agent-runtime:latest") do
      HostedAgentRuntimeReconcileJob.perform_now(@agent.id)
    end
  end

end
