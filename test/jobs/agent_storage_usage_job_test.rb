require "test_helper"

class AgentStorageUsageJobTest < ActiveJob::TestCase

  test "stores a measurement without changing runtime or waking the agent" do
    agent = agents(:research_assistant)
    agent.update_columns(runtime: "offline")
    service = Minitest::Mock.new
    service.expect(:call, { status: "measured", bytes: 4096 })
    Agents::StorageUsage.stub(:new, ->(_agent) { service }) do
      AgentStorageUsageJob.perform_now(agent.id)
    end
    assert_equal "offline", agent.reload.runtime
    assert_equal 4096, agent.storage_usage["bytes"]
    service.verify
  end

  test "deleted agents are ignored" do
    Agents::StorageUsage.stub(:new, ->(*) { flunk "must not measure missing agent" }) do
      assert_nil AgentStorageUsageJob.perform_now(-1)
    end
  end

  test "periodic collector queues hosted agents only" do
    agent = agents(:research_assistant)
    agent.update_columns(runtime: "offline", uuid: SecureRandom.uuid)
    assert_enqueued_with(job: AgentStorageUsageJob, args: [ agent.id ]) do
      CollectAgentStorageUsageJob.perform_now
    end
    jobs = enqueued_jobs.select { |job| job[:job] == AgentStorageUsageJob }
    assert_equal 1, jobs.size
  end

end
