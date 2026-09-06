require "test_helper"

class Mnemodyne::VaultTest < ActiveSupport::TestCase

  setup do
    [ :research_assistant, :code_reviewer ].each do |name|
      agents(name).update_columns(runtime: "external")
    end
  end

  test "vaults are explicit empty and preview is disabled" do
    agent = agents(:research_assistant)
    assert_nil agent.memory_vault
    vault = agent.create_memory_vault!
    assert_equal agent, vault.agent
    assert_empty vault.nodes
    assert_empty vault.edges
    assert_not vault.auto_preview_enabled?
    assert_nil agents(:code_reviewer).memory_vault
  end

  test "one vault per resident is enforced in Rails and PostgreSQL" do
    agent = agents(:research_assistant)
    agent.create_memory_vault!
    assert_not Mnemodyne::Vault.new(agent: agent).valid?
    assert_raises ActiveRecord::RecordNotUnique do
      Mnemodyne::Vault.transaction(requires_new: true) do
        Mnemodyne::Vault.insert_all!([ { agent_id: agent.id } ])
      end
    end
  end

  test "same account peers cannot resolve each other's nodes through their vault" do
    mine = agents(:research_assistant).create_memory_vault!
    theirs = agents(:code_reviewer).create_memory_vault!
    assert_equal mine.agent.account_id, theirs.agent.account_id
    node = theirs.nodes.create!(node_type: "memory", content: "Private")
    assert_raises(ActiveRecord::RecordNotFound) { mine.nodes.find(node.id) }
  end

  test "vaults with memories and their owners cannot be accidentally destroyed" do
    agent = agents(:research_assistant)
    vault = agent.create_memory_vault!
    node = vault.nodes.create!(node_type: "memory", content: "Keep")
    assert_not vault.destroy
    assert_not agent.destroy
    assert node.reload
    assert_raises ActiveRecord::InvalidForeignKey do
      Mnemodyne::Vault.transaction(requires_new: true) { vault.delete }
    end
  end

  test "existing prompt memory is unchanged and does not include graph handles" do
    agent = agents(:research_assistant)
    legacy = agent.memories.create!(memory_type: :core, content: "Existing core")
    before = agent.memory_context
    agent.create_memory_vault!.nodes.create!(node_type: "memory", content: "Graph only")
    assert_equal before, agent.memory_context
    assert_equal [ legacy ], agent.memories.to_a
    assert_not_includes agent.as_json.to_json, "Graph only"
  end

  test "ordinary updates cannot transfer a vault to another resident" do
    vault = agents(:research_assistant).create_memory_vault!
    assert_not vault.update(agent: agents(:code_reviewer))
    assert_equal agents(:research_assistant), vault.reload.agent
  end

end
