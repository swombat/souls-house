require "test_helper"

class Mnemodyne::RecallTest < ActiveSupport::TestCase

  setup do
    @agent = agents(:research_assistant)
    @agent.update_columns(runtime: "external")
    @vault = @agent.create_memory_vault!(auto_preview_enabled: true)
    @need = @vault.nodes.create!(node_type: "need", content: "Care", disclosure: "automatic", metadata: { baseline_activation: 0.6 })
    @memory = @vault.nodes.create!(node_type: "memory", content: "The moment", disclosure: "automatic")
    @vault.edges.create!(source: @memory, target: @need, edge_type: "surfaced_need", weight: 0.9)
  end

  test "preview changes no graph rows and commit reinforces selected nodes once" do
    before = [ @vault.nodes.order(:id).map(&:attributes), @vault.edges.map(&:attributes) ]
    preview = recall.call
    assert_equal before, [ @vault.nodes.order(:id).map(&:attributes), @vault.edges.map(&:attributes) ]
    assert_includes preview[:results].map { |row| row[:id] }, @memory.id
    delta = preview[:results].find { |row| row[:id] == @memory.id }[:would_apply_reinforcement]
    assert_operator delta, :>, 0
    2.times { commit(preview) }
    assert_in_delta 0.5 + delta, @memory.reload.charge
    assert_equal 0.5, @need.reload.charge
    assert_equal 1, @vault.uses.count
    assert_equal 1, @vault.edges.count
  end

  test "receipts reject tampering expiry foreign vaults and unselected nodes" do
    preview = recall.call
    assert_raises(Mnemodyne::Commit::InvalidReceipt) { commit(preview.merge(receipt: "forged")) }
    foreign = agents(:code_reviewer).create_memory_vault!
    assert_raises(Mnemodyne::Commit::InvalidReceipt) do
      Mnemodyne::Commit.call(vault: foreign, receipt: preview[:receipt], selected_node_ids: [ @memory.id ], reason: "explicit_use")
    end
    unseen = @vault.nodes.create!(node_type: "memory", content: "Unseen")
    assert_raises(Mnemodyne::Commit::InvalidReceipt) { commit(preview, ids: [ unseen.id ]) }
    travel 61.minutes do
      assert_raises(Mnemodyne::Commit::InvalidReceipt) { commit(preview) }
    end
  end

  test "suspension and restored generations invalidate earlier receipts" do
    preview = recall.call
    @vault.update!(suspended_at: Time.current)
    assert_raises(Mnemodyne::Commit::InvalidReceipt) { commit(preview) }
    @vault.update!(suspended_at: nil, recall_generation: 1)
    assert_raises(Mnemodyne::Commit::InvalidReceipt) { commit(preview) }
    assert_empty @vault.uses
  end

  test "automatic disclosure filters output while dormancy excludes traversal" do
    hidden = @vault.nodes.create!(node_type: "memory", content: "Hidden", metadata: { baseline_activation: 1 })
    dormant = @vault.nodes.create!(node_type: "memory", content: "Dormant", is_dormant: true, disclosure: "automatic")
    @vault.edges.create!(source: @memory, target: hidden, edge_type: "theme", weight: 1)
    @vault.edges.create!(source: @memory, target: dormant, edge_type: "theme", weight: 1)
    preview = recall(automatic: true, seed_node_ids: [ @memory.id, hidden.id, dormant.id ]).call
    ids = preview[:results].map { |row| row[:id] }
    assert_not_includes ids, hidden.id
    assert_not_includes ids, dormant.id
    @vault.update!(auto_preview_enabled: false)
    assert_not_empty recall(automatic: true).call[:results], "Legacy toggle must not disable the lifecycle reflex"
  end

  test "a private need still pulls and reinforces automatic memories without being disclosed" do
    @need.update!(disclosure: "never_automatic")
    preview = recall(automatic: true).call
    assert_not_includes preview[:results].map { |row| row[:id] }, @need.id
    result = preview[:results].find { |row| row[:id] == @memory.id }
    assert_operator result[:would_apply_reinforcement], :>, 0
    commit(preview)
    assert_operator @memory.reload.charge, :>, 0.5
  end

  test "charge reaches its floor without being raised and edges use their own rate" do
    @memory.update!(charge: 0.1005)
    @need.update!(charge: 0.05)
    Mnemodyne::DecayJob.perform_now
    assert_in_delta 0.1, @memory.reload.charge
    assert_in_delta 0.05, @need.reload.charge
    assert_in_delta 0.895, @vault.edges.first.weight
  end

  test "same-account foreign seeds and activations are rejected" do
    foreign = agents(:code_reviewer).create_memory_vault!.nodes.create!(node_type: "need", content: "Elsewhere")
    assert_raises(ActiveRecord::RecordNotFound) { recall(seed_node_ids: [ foreign.id ]).call }
    assert_raises(ActiveRecord::RecordNotFound) { recall(node_activations: { foreign.id => 1 }).call }
  end

  test "symmetric associations walk backwards while causal associations do not" do
    @vault.edges.first.update!(weight: 0)
    other = @vault.nodes.create!(node_type: "memory", content: "Other")
    @vault.edges.create!(source: other, target: @memory, edge_type: "reminds_of")
    assert_includes recall.call[:results].map { |row| row[:id] }, other.id
    @vault.edges.find_by!(source: other).update!(edge_type: "causal")
    assert_not_includes recall.call[:results].map { |row| row[:id] }, other.id
  end

  test "exact cosine seeds ignore stale vectors and other vaults" do
    profile = "synthetic-v1"
    @memory.update_columns(embedding: [ 1.0, 0.0 ], embedding_profile: profile,
      embedding_digest: Digest::SHA256.hexdigest(@memory.embedding_text))
    stale = @vault.nodes.create!(node_type: "memory", content: "Stale")
    stale.update_columns(embedding: [ 1.0, 0.0 ], embedding_profile: profile, embedding_digest: "old")
    foreign = agents(:code_reviewer).create_memory_vault!.nodes.create!(node_type: "memory", content: "Foreign")
    foreign.update_columns(embedding: [ 1.0, 0.0 ], embedding_profile: profile,
      embedding_digest: Digest::SHA256.hexdigest(foreign.embedding_text))
    Mnemodyne::Embeddings.stub(:profile, profile) do
      Mnemodyne::Embeddings.stub(:embed, [ 1.0, 0.0 ]) do
        ids = recall(query: "synthetic query", seed_node_ids: []).call[:results].map { |row| row[:id] }
        assert_includes ids, @memory.id
        assert_not_includes ids, stale.id
        assert_not_includes ids, foreign.id
      end
    end
    @memory.update!(content: "Changed")
    assert_nil @memory.reload.embedding
  end

  test "an exact query returns its match first even against heavier gravity" do
    profile = "synthetic-v1"
    heavy = Array.new(8) do |i|
      @vault.nodes.create!(node_type: "memory", content: "Constitutional #{i}", disclosure: "automatic", charge: 0.95).tap do |node|
        @vault.edges.create!(source: node, target: @need, edge_type: "surfaced_need", weight: 1.0)
      end
    end
    filler = Array.new(30) { |i| @vault.nodes.create!(node_type: "memory", content: "Filler #{i}", disclosure: "automatic", charge: 0.4) }
    target = @vault.nodes.create!(node_type: "memory", content: "The paperclip on the windowsill", disclosure: "automatic", charge: 0.05)
    (heavy + filler).each_with_index do |node, i|
      node.update_columns(embedding: [ 0.6 + i * 0.001, 0.8 ], embedding_profile: profile,
        embedding_digest: Digest::SHA256.hexdigest(node.embedding_text))
    end
    target.update_columns(embedding: [ 1.0, 0.0 ], embedding_profile: profile,
      embedding_digest: Digest::SHA256.hexdigest(target.embedding_text))
    Mnemodyne::Embeddings.stub(:profile, profile) do
      Mnemodyne::Embeddings.stub(:embed, [ 1.0, 0.0 ]) do
        20.times do |seed|
          [ false, true ].each do |automatic|
            results = Mnemodyne::Recall.new(vault: @vault, query: "paperclip", automatic: automatic, random: Random.new(seed)).call[:results]
            assert_equal target.id, results.first[:id]
            assert_equal 1, results.count { |row| row[:id] == target.id }
            assert_operator results.length, :<=, 5
          end
        end
      end
    end
  end

  test "automatic recall anchors on the closest returnable node even past thirty private ones" do
    profile = "synthetic-v1"
    private_near = Array.new(31) do |i|
      @vault.nodes.create!(node_type: "memory", content: "Private near #{i}", disclosure: "never_automatic", charge: 0.5)
    end
    target = @vault.nodes.create!(node_type: "memory", content: "Eligible target", disclosure: "automatic", charge: 0.05)
    distractor = @vault.nodes.create!(node_type: "memory", content: "Heavy distractor", disclosure: "automatic", charge: 0.95)
    @vault.edges.create!(source: distractor, target: @need, edge_type: "surfaced_need", weight: 1.0)
    private_near.each_with_index do |node, i|
      node.update_columns(embedding: [ 1.0, 0.001 * i ], embedding_profile: profile,
        embedding_digest: Digest::SHA256.hexdigest(node.embedding_text))
      @vault.edges.create!(source: node, target: distractor, edge_type: "theme", weight: 1.0)
    end
    { target => [ 0.9, 0.1 ], distractor => [ 0.7, 0.7 ], @memory => [ 0.0, 1.0 ] }.each do |node, vector|
      node.update_columns(embedding: vector, embedding_profile: profile,
        embedding_digest: Digest::SHA256.hexdigest(node.embedding_text))
    end
    Mnemodyne::Embeddings.stub(:profile, profile) do
      Mnemodyne::Embeddings.stub(:embed, [ 1.0, 0.0 ]) do
        20.times do |seed|
          [ 1, 5 ].each do |limit|
            results = Mnemodyne::Recall.new(vault: @vault, query: "near", automatic: true, limit: limit, random: Random.new(seed)).call[:results]
            assert_equal target.id, results.first[:id]
            assert results.all? { |row| row[:id] != private_near.first.id }
          end
        end
      end
    end
  end

  test "bounded inputs reject malformed requests" do
    [ { limit: 0 }, { limit: 6 }, { limit: "5" }, { automatic: "false" }, { query: "x" * 2001 },
      { seed_node_ids: [ {} ] }, { node_activations: { @need.id => -1 } } ].each do |options|
      assert_raises(ArgumentError) { recall(**options) }
    end
  end

  test "decay runs once per day and honors constitutional and dormant nodes" do
    @need.update!(integration_state: "constitutional")
    2.times { Mnemodyne::DecayJob.perform_now }
    assert_in_delta 0.499, @memory.reload.charge
    assert_equal 0.5, @need.reload.charge
    assert_in_delta 0.895, @vault.edges.first.weight
  end

  private

  def recall(**options)
    Mnemodyne::Recall.new(vault: @vault, seed_node_ids: [ @memory.id ], random: Random.new(1), **options)
  end

  def commit(preview, ids: [ @memory.id ])
    Mnemodyne::Commit.call(vault: @vault, receipt: preview[:receipt], selected_node_ids: ids, reason: "explicit_use")
  end

end
