require "test_helper"

class Mnemodyne::ErasureTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external", uuid: SecureRandom.uuid)
    @vault = @agent.create_memory_vault!
    @node = @vault.nodes.create!(node_type: "memory", content: "Synthetic memory")
    @envelope = Mnemodyne::Checkpoint.export(@vault)
    @receipt = Mnemodyne::Erasure.export_receipt(@vault, @envelope)
  end

  test "requires an authentic current export and the resident identity" do
    assert_raises(Mnemodyne::Erasure::Invalid) { request(receipt: "forged") }
    assert_raises(Mnemodyne::Erasure::Invalid) { request(confirmation: "someone else") }
    @node.update!(content: "Changed since export")
    assert_raises(Mnemodyne::Erasure::Invalid) { request }
    assert_nil @vault.reload.erase_after
  end

  test "constitutional material needs its own explicit acknowledgement" do
    @node.update!(integration_state: "constitutional")
    @receipt = Mnemodyne::Erasure.export_receipt(@vault, Mnemodyne::Checkpoint.export(@vault))
    assert_raises(Mnemodyne::Erasure::Invalid) { request }
    request(include_constitutional: true)
    assert @vault.reload.erase_constitutional?
  end

  test "grace is cancellable and retries do not postpone it" do
    request
    deadline = @vault.erase_after
    request
    assert_equal deadline, @vault.reload.erase_after
    assert_not Mnemodyne::Erasure.perform(@vault)
    assert_raises(Mnemodyne::Write::Conflict) do
      Mnemodyne::Write.call(vault: @vault, key: "blocked", operation: "write", payload: {}) { flunk }
    end
    Mnemodyne::Erasure.cancel(@vault)
    travel 8.days do
      assert_not Mnemodyne::Erasure.perform(@vault)
      assert_equal "Synthetic memory", @node.reload.content
    end
  end

  test "expiry purges only the requested graph and records anti resurrection marker" do
    peer = agents(:code_reviewer).create_memory_vault!
    peer.nodes.create!(node_type: "memory", content: "Peer remains")
    request
    travel 8.days do
      assert Mnemodyne::Erasure.perform(@vault)
      assert_nil Mnemodyne::Vault.find_by(id: @vault.id)
      assert @agent.reload.memory_erased_at?
      assert_equal "Peer remains", peer.nodes.first.content
    end
  end

  test "expiry holds rather than deleting a graph changed by a privileged writer" do
    request
    @node.update!(content: "Changed during grace")
    travel 8.days do
      assert_raises(Mnemodyne::Erasure::Invalid) { Mnemodyne::Erasure.perform(@vault) }
      assert_equal "Changed during grace", @node.reload.content
    end
  end

  private

  def request(**options)
    Mnemodyne::Erasure.request(@vault, **{ receipt: @receipt, confirmation: @agent.uuid }.merge(options))
  end

end
