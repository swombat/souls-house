require "test_helper"

class AgentHomeStorageJobTest < ActiveJob::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", home_storage: {}, home_storage_requested_at: nil, storage_usage: {})
  end

  test "a local resident already measured daily is never walked from a card" do
    @agent.update_columns(storage_usage: { "status" => "measured", "bytes" => 5 })
    assert_no_enqueued_jobs { AgentHomeStorageJob.request_refresh(@agent, remote: false) }
  end

  test "a local resident never measured gets one first walk by the daily walker, not a second walker" do
    assert_enqueued_jobs 1, only: AgentStorageUsageJob do
      3.times { AgentHomeStorageJob.request_refresh(@agent, remote: false) }
    end
    assert_no_enqueued_jobs only: AgentHomeStorageJob
    travel 61.minutes do
      assert_enqueued_jobs(1, only: AgentStorageUsageJob) { AgentHomeStorageJob.request_refresh(@agent, remote: false) }
    end
  end

  test "a VM resident is walked by its runner at most once an hour, on the background queue" do
    assert_enqueued_jobs 1, only: AgentHomeStorageJob, queue: "background" do
      3.times { AgentHomeStorageJob.request_refresh(@agent, remote: true) }
    end
    service = Struct.new(:call).new({ "status" => "measured", "bytes" => 12 })
    Agents::RemoteRuntime.stub(:remote?, true) do
      Agents::HomeStorage.stub(:new, ->(*) { service }) { AgentHomeStorageJob.perform_now(@agent.id) }
    end
    assert_equal 12, @agent.reload.home_storage["bytes"]
    travel 30.minutes do
      assert_no_enqueued_jobs(only: AgentHomeStorageJob) { AgentHomeStorageJob.request_refresh(@agent, remote: true) }
    end
    travel 61.minutes do
      assert_enqueued_jobs(1, only: AgentHomeStorageJob) { AgentHomeStorageJob.request_refresh(@agent, remote: true) }
    end
  end

  test "the job walks only VM residents, and ignores deleted and deprecated ones" do
    Agents::HomeStorage.stub(:new, ->(*) { flunk "must not walk" }) do
      AgentHomeStorageJob.perform_now(@agent.id)
      AgentHomeStorageJob.perform_now(-1)
      @agent.update_columns(runtime: "deprecated")
      Agents::RemoteRuntime.stub(:remote?, true) { AgentHomeStorageJob.perform_now(@agent.id) }
    end
    assert_no_enqueued_jobs { AgentHomeStorageJob.request_refresh(@agent, remote: true) }
  end

end
