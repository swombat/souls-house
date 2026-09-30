require "test_helper"
require "erb"
require "yaml"

class ResidentTurnQueueConfigurationTest < ActiveSupport::TestCase

  test "ordinary work retains a pool that cannot consume resident polling jobs" do
    configuration = YAML.safe_load(ERB.new(Rails.root.join("config/queue.yml").read).result, aliases: true)
    workers = configuration.fetch("production").fetch("workers")
    ordinary = workers.find { |worker| Array(worker["queues"]).include?("default") }
    resident = workers.find { |worker| Array(worker["queues"]).include?("resident_dispatch") }
    assert ordinary
    assert resident
    assert_not_includes Array(ordinary["queues"]), "*"
    assert_not_includes Array(ordinary["queues"]), "resident_dispatch"
    assert_operator ordinary["threads"], :>, 0
    assert_operator resident["threads"], :>, 0
  end

end
