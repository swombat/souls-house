require "test_helper"

class HouseSampling::ContainerStatsTest < ActiveSupport::TestCase

  test "maps docker stats rows to residents by container name and ignores other containers" do
    agent = agents(:research_assistant)
    agent.update_columns(container_name: "resident-abc")
    output = [
      { Name: "resident-abc", CPUPerc: "12.50%", MemUsage: "1.5GiB / 8GiB" }.to_json,
      { Name: "souls-house-web", CPUPerc: "80.00%", MemUsage: "900MiB / 125GiB" }.to_json,
      "not json"
    ].join("\n")
    status = Struct.new(:success?).new(true)
    Open3.stub(:capture2, [ output, status ]) do
      result = HouseSampling::ContainerStats.new.call
      assert_equal({ agent.id.to_s => { "cpu" => 12.5, "mem" => (1.5 * 1024**3).round } }, result)
    end
  end

  test "a failing docker call is an empty reading, not an error" do
    agents(:research_assistant).update_columns(container_name: "resident-abc")
    Open3.stub(:capture2, ->(*) { raise Errno::ENOENT }) do
      assert_equal({}, HouseSampling::ContainerStats.new.call)
    end
  end

end
