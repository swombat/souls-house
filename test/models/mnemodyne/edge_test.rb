require "test_helper"

class Mnemodyne::EdgeTest < ActiveSupport::TestCase

  setup do
    [ :research_assistant, :code_reviewer, :other_account_agent ].each do |name|
      agents(name).update_columns(runtime: "external")
    end
    @vault = agents(:research_assistant).create_memory_vault!
    @source = @vault.nodes.create!(node_type: "memory", content: "Moment")
    @target = @vault.nodes.create!(node_type: "need", content: "Care")
  end

  test "stores typed weighted associations" do
    edge = @vault.edges.create!(source: @source, target: @target, edge_type: "surfaced_need", weight: 0.8)
    assert_equal [ edge ], @source.outgoing_edges.to_a
    assert_equal [ edge ], @target.incoming_edges.to_a
    assert_equal 0.8, edge.reload.weight
  end

  test "both endpoints must belong to the edge vault including same-account peers" do
    [ :code_reviewer, :other_account_agent ].each do |fixture|
      foreign = agents(fixture).create_memory_vault!.nodes.create!(node_type: "memory", content: "Private")
      foreign_peer = foreign.vault.nodes.create!(node_type: "memory", content: "Also private")
      [ { source: foreign, target: @target }, { source: @source, target: foreign },
        { source: foreign, target: foreign_peer } ].each do |endpoints|
        edge = @vault.edges.build(**endpoints, edge_type: "reminds_of")
        assert_not edge.valid?
        assert_database_rejects(ActiveRecord::InvalidForeignKey) { edge.save!(validate: false) }
      end
    end
  end

  test "foreign endpoints cannot be substituted with a raw update" do
    edge = @vault.edges.create!(source: @source, target: @target, edge_type: "theme")
    foreign = agents(:code_reviewer).create_memory_vault!.nodes.create!(node_type: "memory", content: "Private")
    [ :source_id, :target_id ].each do |attribute|
      assert_database_rejects(ActiveRecord::InvalidForeignKey) { edge.update_columns(attribute => foreign.id) }
      edge.reload
    end
  end

  test "a connected node cannot move to another vault through raw SQL" do
    @vault.edges.create!(source: @source, target: @target, edge_type: "theme")
    other = agents(:code_reviewer).create_memory_vault!
    assert_database_rejects(ActiveRecord::InvalidForeignKey) do
      Mnemodyne::Node.where(id: @source.id).update_all(vault_id: other.id)
    end
  end

  test "self loops are rejected but reciprocal edges and cycles are valid" do
    loop_edge = @vault.edges.build(source: @source, target: @source, edge_type: "theme")
    assert_not loop_edge.valid?
    assert_database_rejects { loop_edge.save!(validate: false) }
    @vault.edges.create!(source: @source, target: @target, edge_type: "theme")
    @vault.edges.create!(source: @target, target: @source, edge_type: "theme")
    third = @vault.nodes.create!(node_type: "person", content: "Daniel")
    @vault.edges.create!(source: @target, target: third, edge_type: "theme")
    @vault.edges.create!(source: third, target: @source, edge_type: "theme")
    assert_equal 4, @vault.edges.count
  end

  test "endpoint pairs can carry multiple types but not duplicate typed edges" do
    @vault.edges.create!(source: @source, target: @target, edge_type: "theme")
    duplicate = @vault.edges.build(source: @source, target: @target, edge_type: "theme")
    assert_not duplicate.valid?
    assert_database_rejects(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    assert @vault.edges.create!(source: @source, target: @target, edge_type: "resident_defined")
  end

  test "weight constraints reject nonfinite and out of range raw writes" do
    edge = @vault.edges.create!(source: @source, target: @target, edge_type: "theme")
    [ 0, 1 ].each { |weight| assert edge.update(weight: weight) }
    [ -0.1, 1.1, Float::NAN, Float::INFINITY, -Float::INFINITY ].each do |weight|
      edge.weight = weight
      assert_not edge.valid?
      assert_database_rejects { edge.save!(validate: false) }
      edge.reload
    end
  end

  test "invalid edge vocabulary and metadata are rejected" do
    edge = @vault.edges.build(source: @source, target: @target, edge_type: "theme")
    [ "", "Two Words", "x" * 101 ].each do |type|
      edge.edge_type = type
      assert_not edge.valid?
    end
    edge.edge_type = "theme"
    edge.metadata = []
    assert_not edge.valid?
    assert_database_rejects { edge.save!(validate: false) }
  end

  test "deleting a node removes incident edges but preserves unrelated nodes and edges" do
    third = @vault.nodes.create!(node_type: "person", content: "Daniel")
    @vault.edges.create!(source: @source, target: @target, edge_type: "theme")
    @vault.edges.create!(source: third, target: @source, edge_type: "theme")
    preserved = @vault.edges.create!(source: third, target: @target, edge_type: "theme")
    @source.delete
    assert_equal [ preserved ], @vault.edges.to_a
    assert_equal 2, @vault.nodes.count
  end

  test "ordinary updates cannot reassign edge ownership" do
    edge = @vault.edges.create!(source: @source, target: @target, edge_type: "theme")
    other = agents(:code_reviewer).create_memory_vault!
    assert_not edge.update(vault: other)
    assert_equal @vault, edge.reload.vault
  end

  private

  def assert_database_rejects(error = ActiveRecord::StatementInvalid, &block)
    assert_raises(error) do
      Mnemodyne::Edge.transaction(requires_new: true, &block)
    end
  end

end
