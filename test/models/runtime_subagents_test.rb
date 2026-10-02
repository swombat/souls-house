require "test_helper"

class RuntimeSubagentsTest < ActiveSupport::TestCase

  test "distinct overflow is bounded counted once and honestly marked at saturation" do
    projection = RuntimeSubagents.new
    1_024.times { |index| projection.observe(child(index), run_id: "run") }
    assert_equal 32, projection.public_snapshot["subagents"].size
    assert_equal 992, projection.public_snapshot["subagents_overflow"]
    assert_not projection.public_snapshot["subagents_overflow_capped"]
    3.times { projection.observe(child(50), run_id: "run") }
    assert_not projection.public_snapshot["subagents_overflow_capped"]
    projection.observe(child(1_024), run_id: "run")
    assert projection.public_snapshot["subagents_overflow_capped"]
    assert_equal 992, projection.public_snapshot["subagents_overflow"]
    assert_equal 1_024, projection.state["identities"].size
    assert projection.state["identities"].all? { |identity| identity.match?(/\A[0-9a-f]{64}\z/) }
    assert_equal 1, projection.observe(child(0).merge("status" => "completed"), run_id: "run")["ordinal"]
    assert_equal "completed", projection.public_snapshot["subagents"].first["status"]
  end

  test "heartbeat cannot replace an unknown status even with cached completion" do
    projection = RuntimeSubagents.new
    projection.observe(child(0), run_id: "run")
    projection.gap!
    %w[running completed errored shutdown].each do |status|
      projection.observe(child(0).merge("status" => status), run_id: "run", heartbeat: true)
      assert_equal "unknown", projection.public_snapshot["subagents"].first["status"]
    end
    projection.observe(child(0).merge("status" => "completed"), run_id: "run")
    assert_equal "completed", projection.public_snapshot["subagents"].first["status"]
    projection.observe(child(0), run_id: "run")
    assert_equal "running", projection.public_snapshot["subagents"].first["status"]
  end

  test "heartbeat discovery is unknown and absent metadata stays absent" do
    projection = RuntimeSubagents.new
    projection.observe(child(0).except("model", "agent_nickname"), run_id: "run", heartbeat: true)
    assert_equal({ "ordinal" => 1, "nickname" => nil, "model" => nil, "status" => "unknown" },
      projection.public_snapshot["subagents"].first)
  end

  private

  def child(index)
    { "child_process_id" => "private-child-#{index}", "agent_nickname" => "Helper", "model" => "synthetic", "status" => "running" }
  end

end
