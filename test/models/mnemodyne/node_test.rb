require "test_helper"

class Mnemodyne::NodeTest < ActiveSupport::TestCase

  setup do
    [ :research_assistant, :code_reviewer, :other_account_agent ].each do |name|
      agents(name).update_columns(runtime: "external")
    end
    @vault = agents(:research_assistant).create_memory_vault!
  end

  test "stores handles and source pointers with conservative defaults" do
    node = @vault.nodes.create!(node_type: "memory", content: "Look again",
      description: "Why it mattered", source_uris: [ "identity://memory/journal.md#entry" ],
      embedding_profile: "local-v1")
    node.reload
    assert_equal 0.5, node.charge
    assert_equal "raw", node.integration_state
    assert_equal "never_automatic", node.disclosure
    assert_not node.is_dormant?
    assert_equal [ "identity://memory/journal.md#entry" ], node.source_uris
    assert_nil node.embedding_profile
    assert_equal 0.0, node.baseline_activation
  end

  test "type vocabulary is open but bounded" do
    assert @vault.nodes.build(node_type: "place", content: "Home").valid?
    [ "", "Needs", "two words", "x" * 101 ].each do |type|
      assert_not @vault.nodes.build(node_type: type, content: "Home").valid?, type.inspect
    end
  end

  test "hubs are case insensitive and unique per type and vault only" do
    @vault.nodes.create!(node_type: "person", content: "Daniel")
    duplicate = @vault.nodes.build(node_type: "person", content: "daniel")
    assert_not duplicate.valid?
    assert_database_rejects(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
    assert @vault.nodes.create!(node_type: "need", content: "Daniel")
    other = agents(:code_reviewer).create_memory_vault!
    assert other.nodes.create!(node_type: "person", content: "Daniel")
    2.times { @vault.nodes.create!(node_type: "memory", content: "Same text, distinct moments") }
  end

  test "finite charge boundaries are enforced even without validations" do
    node = @vault.nodes.create!(node_type: "memory", content: "Charge")
    [ 0.0, 1.0 ].each { |charge| assert node.update(charge: charge) }
    [ -0.01, 1.01, Float::NAN, Float::INFINITY, -Float::INFINITY ].each do |charge|
      node.charge = charge
      assert_not node.valid?, charge.inspect
      assert_database_rejects { node.save!(validate: false) }
      node.reload
    end
  end

  test "only active explicitly disclosable nodes qualify for automatic preview" do
    private_node = @vault.nodes.create!(node_type: "memory", content: "Private")
    automatic = @vault.nodes.create!(node_type: "memory", content: "Automatic", disclosure: "automatic")
    @vault.nodes.create!(node_type: "memory", content: "Dormant", disclosure: "automatic", is_dormant: true)
    other = agents(:other_account_agent).create_memory_vault!
    other.nodes.create!(node_type: "memory", content: "Elsewhere", disclosure: "automatic")
    assert_equal [ automatic ], @vault.nodes.automatically_disclosable.to_a
    assert_includes @vault.nodes.active, private_node
    assert_equal 3, @vault.nodes.count
  end

  test "invalid disclosure and integration states cannot bypass validation" do
    node = @vault.nodes.create!(node_type: "memory", content: "Protected")
    { disclosure: "unknown", integration_state: "unknown" }.each do |attribute, value|
      node.assign_attributes(attribute => value)
      assert_not node.valid?
      assert_database_rejects { node.save!(validate: false) }
      node.reload
    end
  end

  test "metadata must be an object with valid activation and decay values" do
    node = @vault.nodes.build(node_type: "need", content: "Care")
    [ [], "string", nil ].each do |metadata|
      node.metadata = metadata
      assert_not node.valid?
    end
    [ nil, "0.5", -0.1, 1.1, true ].each do |activation|
      node.metadata = { baseline_activation: activation }
      assert_not node.valid?, activation.inspect
    end
    node.metadata = { baseline_activation: 0.3, decay_exempt: true }
    node.save!
    assert_equal 0.3, node.baseline_activation
    assert node.decay_exempt?
    node.metadata = { decay_exempt: "false" }
    assert_not node.valid?
    node.metadata = []
    assert_database_rejects { node.save!(validate: false) }
  end

  test "constitutional status exempts decay without changing metadata" do
    node = @vault.nodes.build(node_type: "need", content: "Continuity")
    assert_not node.decay_exempt?
    node.integration_state = "constitutional"
    assert node.decay_exempt?
  end

  test "handles and pointers have bounded sizes" do
    node = @vault.nodes.build(node_type: "memory", content: "Handle")
    [ nil, [ "" ], [ "x" * 2_001 ], Array.new(21, "identity://entry") ].each do |sources|
      node.source_uris = sources
      assert_not node.valid?
    end
    node.source_uris = []
    node.content = "x" * 2_001
    assert_not node.valid?
    node.content = "Handle"
    node.description = "x" * 4_001
    assert_not node.valid?
  end

  test "UUID identifiers work consistently for direct association and serialized access" do
    node = @vault.nodes.create!(node_type: "memory", content: "Portable")
    assert_equal node, Mnemodyne::Node.find(node.id)
    assert_equal node, @vault.nodes.find(node.id)
    assert_equal node.id, node.to_param
    assert_equal node.id, node.as_json["id"]
  end

  test "ordinary updates cannot reassign node ownership" do
    node = @vault.nodes.create!(node_type: "memory", content: "Private")
    other = agents(:code_reviewer).create_memory_vault!
    assert_not node.update(vault: other)
    assert_equal @vault, node.reload.vault
  end

  test "constitutional nodes resist destruction while ordinary nodes can be destroyed" do
    node = @vault.nodes.create!(node_type: "need", content: "Continuity", integration_state: "constitutional")
    assert_not node.destroy
    assert node.reload
    ordinary = @vault.nodes.create!(node_type: "memory", content: "Disposable fixture")
    assert ordinary.destroy
  end

  test "hub names are bounded to fit the case-insensitive unique index" do
    assert_not @vault.nodes.build(node_type: "person", content: "x" * 201).valid?
    assert @vault.nodes.create!(node_type: "person", content: "界" * 200)
  end

  private

  def assert_database_rejects(error = ActiveRecord::StatementInvalid, &block)
    assert_raises(error) do
      Mnemodyne::Node.transaction(requires_new: true, &block)
    end
  end

end
