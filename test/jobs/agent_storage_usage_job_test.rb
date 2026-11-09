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

  test "periodic collector spaces residents out instead of measuring all at once" do
    first, second = agents(:research_assistant), agents(:code_reviewer)
    [ first, second ].each { |agent| agent.update_columns(runtime: "offline", uuid: SecureRandom.uuid) }
    freeze_time do
      CollectAgentStorageUsageJob.perform_now
      times = enqueued_jobs.select { |job| job[:job] == AgentStorageUsageJob }.map { |job| job[:at] || Time.current.to_f }.sort
      assert_equal 2, times.size
      assert_in_delta CollectAgentStorageUsageJob::SPACING.to_f, times.last - times.first, 0.01
    end
  end

  test "collector runs daily, before the 04:40 storage sample keeps its history" do
    schedule = YAML.load_file(Rails.root.join("config/recurring.yml"), aliases: true)
    entries = schedule.values.grep(Hash).filter_map { |env| env["agent_storage_usage"] }
    assert entries.any?
    assert entries.all? { |entry| entry["schedule"] == "every day at 4:15am" }
  end

end
