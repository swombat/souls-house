require "test_helper"

class AgentPlacementTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
  end

  test "existing residents need no placement and local records use safe defaults" do
    assert_nil @agent.placement
    placement = @agent.create_placement!

    assert_equal "local", placement.backend
    assert_equal "pending", placement.state
    assert_equal 1, placement.generation
    assert_nil placement.provider_server_id
    assert_nil placement.runtime_endpoint
    assert_equal @agent, placement.agent
    assert_equal placement, @agent.reload.placement
  end

  test "backend and lifecycle state are bounded" do
    placement = @agent.build_placement
    AgentPlacement::BACKENDS.each do |backend|
      placement.backend = backend
      assert placement.valid?, placement.errors.full_messages.join(", ")
    end
    AgentPlacement::STATES.each do |state|
      placement.assign_attributes(backend: "local", state: state)
      assert placement.valid?, placement.errors.full_messages.join(", ")
    end
    placement.assign_attributes(backend: "another_cloud", state: "running")
    assert_not placement.valid?
    assert placement.errors.added?(:backend, :inclusion, value: "another_cloud")
    assert placement.errors.added?(:state, :inclusion, value: "running")
  end

  test "local placement rejects remote metadata even when not ready" do
    [ { provider_server_id: 123 }, { runtime_endpoint: "https://runtime.example.test" } ].each do |attributes|
      placement = @agent.build_placement(**attributes)
      assert_not placement.valid?
      assert placement.errors[attributes.keys.first].present?
    end
  end

  test "remote ready requires both server identity and endpoint" do
    placement = @agent.build_placement(backend: "hetzner_cloud")
    assert placement.valid?
    placement.state = "ready"
    assert_not placement.valid?
    assert placement.errors[:provider_server_id].present?
    assert placement.errors[:runtime_endpoint].present?
    placement.provider_server_id = 123
    assert_not placement.valid?
    placement.runtime_endpoint = "https://runtime.example.test:8443/"
    assert placement.valid?, placement.errors.full_messages.join(", ")
    placement.save!
    assert_equal 123, placement.reload.provider_server_id
  end

  test "server identity must be a positive integer whenever populated" do
    [ 0, -1, 1.5, "not-a-number", "12wrong" ].each do |server_id|
      placement = @agent.build_placement(backend: "hetzner_cloud", provider_server_id: server_id)
      assert_not placement.valid?, "accepted #{server_id.inspect}"
      assert placement.errors[:provider_server_id].present?
    end
  end

  test "remote endpoints must be HTTPS root URLs without credentials queries or fragments" do
    [
      "", "http://runtime.example.test", "https:///trigger", "not a URL",
      "https://user:password@runtime.example.test", "https://runtime.example.test/#fragment",
      "https://runtime.example.test/?token=secret", "https://runtime.example.test/trigger"
    ].each do |endpoint|
      placement = @agent.build_placement(backend: "hetzner_cloud", runtime_endpoint: endpoint)
      assert_not placement.valid?, "accepted #{endpoint.inspect}"
      assert placement.errors[:runtime_endpoint].present?
    end
  end

  test "generation must be an integer at least one" do
    [ nil, 0, -1, 1.5, "not-a-number" ].each do |generation|
      placement = @agent.build_placement(generation: generation)
      assert_not placement.valid?, "accepted #{generation.inspect}"
      assert placement.errors[:generation].present?
    end
    assert @agent.build_placement(generation: 2).valid?
  end

  test "a resident has only one placement at model and database boundaries" do
    @agent.create_placement!
    duplicate = AgentPlacement.new(agent: @agent)
    assert_not duplicate.valid?
    assert duplicate.errors[:agent_id].present?

    assert_raises(ActiveRecord::RecordNotUnique) do
      AgentPlacement.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end
  end

  test "a provider server cannot belong to multiple residents" do
    @agent.create_placement!(backend: "hetzner_cloud", provider_server_id: 123)
    duplicate = AgentPlacement.new(agent: agents(:code_reviewer), backend: "hetzner_cloud", provider_server_id: 123)
    assert_not duplicate.valid?
    assert duplicate.errors[:provider_server_id].present?

    assert_raises(ActiveRecord::RecordNotUnique) do
      AgentPlacement.transaction(requires_new: true) { duplicate.save!(validate: false) }
    end
  end

  test "multiple local placements can have no provider server" do
    @agent.create_placement!
    assert agents(:code_reviewer).create_placement!
  end

  test "database rejects missing residents and invalid generation or server identity" do
    placement = @agent.create_placement!
    [
      [ :agent_id, -1, ActiveRecord::InvalidForeignKey ],
      [ :agent_id, nil, ActiveRecord::NotNullViolation ],
      [ :generation, 0, ActiveRecord::StatementInvalid ],
      [ :generation, nil, ActiveRecord::NotNullViolation ],
      [ :provider_server_id, 0, ActiveRecord::StatementInvalid ]
    ].each do |attribute, value, error|
      assert_raises(error) do
        AgentPlacement.transaction(requires_new: true) { placement.update_columns(attribute => value) }
      end
      placement.reload
    end
  end

end
