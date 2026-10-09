require "test_helper"

class HouseSampleJobsTest < ActiveSupport::TestCase

  test "host sample stores the reading and its per-resident stats, and prunes old fine samples" do
    old = HouseSample.create!(kind: "host", subject: "house", sampled_at: 40.days.ago, metrics: {})
    daily = HouseSample.create!(kind: "restic_storage", sampled_at: 400.days.ago, metrics: { "bytes" => 1 })
    reader = Object.new
    reader.define_singleton_method(:call) { |previous:| { "load_1" => 0.5, "previous_seen" => previous.present? } }
    stats = Object.new
    stats.define_singleton_method(:call) { { "1" => { "cpu" => 3.0, "mem" => 10 } } }
    HouseSampling::HostReader.stub(:new, ->(*) { reader }) do
      HouseSampling::ContainerStats.stub(:new, ->(*) { stats }) do
        HouseHostSampleJob.perform_now
        HouseHostSampleJob.perform_now
      end
    end
    samples = HouseSample.of_kind("host").where(subject: "house").order(:sampled_at).last(2)
    assert_equal 0.5, samples.last.metrics["load_1"]
    assert samples.last.metrics["previous_seen"]
    assert_equal({ "1" => { "cpu" => 3.0, "mem" => 10 } }, samples.last.metrics["residents"])
    assert_not HouseSample.exists?(old.id)
    assert HouseSample.exists?(daily.id)
  end

  test "storage sample keeps a daily history of measured resident disk and prices" do
    agent = agents(:research_assistant)
    agent.update_columns(runtime: Agent::HOSTED_RUNTIMES.first, storage_usage: { "status" => "measured", "bytes" => 2048 })
    restic = Object.new
    restic.define_singleton_method(:enabled?) { false }
    HouseSampling::ResticStorage.stub(:new, restic) do
      HouseStorageSampleJob.perform_now
    end
    assert_equal 2048, HouseSample.of_kind("resident_disk").find_by(agent:).metrics["bytes"]
    pricing = HouseSample.of_kind("pricing").last.metrics
    assert pricing["s3_usd_per_gb_month"].positive?
  end

end
