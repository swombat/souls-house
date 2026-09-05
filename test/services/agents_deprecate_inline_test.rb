require "test_helper"

class AgentsDeprecateInlineTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "inline")
  end

  test "explicit transition preserves identity and intent and is idempotent" do
    @agent.update_columns(paused: true, active: false)
    @agent.trigger_bearer_token = "old-trigger"
    # Legacy values are intentionally not valid for ordinary writes.
    @agent.save!(validate: false)
    original = @agent.attributes.slice("name", "system_prompt", "model_id", "paused", "active", "birth_committed_at")
    assert_equal [ @agent.id ], Agents::DeprecateInline.call(expected_ids: [ @agent.id ])
    @agent.reload
    assert_equal "deprecated", @agent.runtime
    assert_equal original, @agent.attributes.slice(*original.keys)
    assert_nil @agent.trigger_bearer_token
    assert_equal Agents::DeprecateInline::REASON, @agent.deprecation_reason
    timestamp = @agent.deprecated_at
    Agents::DeprecateInline.call(expected_ids: [ @agent.id ])
    assert_equal timestamp, @agent.reload.deprecated_at
  end

  test "changed inventory fails atomically" do
    agents(:code_reviewer).update_columns(runtime: "inline")
    assert_raises(Agents::DeprecateInline::InventoryChanged) do
      Agents::DeprecateInline.call(expected_ids: [ @agent.id ])
    end
    assert_equal "inline", @agent.reload.runtime
    assert_nil @agent.deprecated_at
  end

  test "migration and contradictory harness metadata require human resolution" do
    %w[migrating external provisioning].each do |runtime|
      @agent.update_columns(runtime: runtime)
      assert_raises(Agents::DeprecateInline::InventoryChanged) do
        Agents::DeprecateInline.call(expected_ids: [ @agent.id ])
      end
    end
    @agent.update_columns(runtime: "inline", container_name: "do-not-touch")
    assert_raises(Agents::DeprecateInline::InventoryChanged) do
      Agents::DeprecateInline.call(expected_ids: [ @agent.id ])
    end
    assert_equal "inline", @agent.reload.runtime
  end

  test "inventory contains no credential values" do
    @agent.trigger_bearer_token = "secret-trigger"
    @agent.save!(validate: false)
    inventory = Agents::DeprecateInline.inventory
    assert_equal %i[id runtime updated_at harness_metadata], inventory.find { |row| row[:id] == @agent.id }.keys
    refute_includes inventory.to_json, "secret-trigger"
  end

end
