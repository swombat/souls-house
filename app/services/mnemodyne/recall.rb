class Mnemodyne::Recall

  VERSION = "house-v1"
  MAX_NODES = 5_000
  MAX_EDGES = 20_000
  SYMMETRIC_TYPES = %w[theme feeling reminds_of co_retrieved knows family colleague friend relates_to].freeze
  class CapacityExceeded < StandardError; end

  def initialize(vault:, query: nil, seed_node_ids: [], node_activations: {}, automatic: false, limit: 5, random: Random.new)
    raise ArgumentError unless query.nil? || (query.is_a?(String) && query.length <= 2_000)
    raise ArgumentError unless limit.is_a?(Integer) && limit.between?(1, 5)
    raise ArgumentError unless seed_node_ids.is_a?(Array) && seed_node_ids.length <= 10
    raise ArgumentError unless node_activations.is_a?(Hash) && node_activations.length <= 50
    raise ArgumentError unless [ true, false ].include?(automatic)
    @vault, @query, @seed_ids, @automatic, @limit, @random = vault, query, seed_node_ids, automatic, limit, random
    @activations = node_activations.transform_keys(&:to_s)
    (@seed_ids + @activations.keys).each do |id|
      raise ArgumentError unless id.is_a?(String) && id.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
    end
    @activations.each_value do |value|
      raise ArgumentError unless value.is_a?(Numeric) && value.finite? && value.between?(0, 1)
    end
  end

  def call
    return empty if @vault.erasure_requested_at?
    # Private needs still pull. Disclosure governs returned handles, not the
    # resident's private traversal; dormancy excludes nodes from both.
    scope = @vault.nodes.active
    nodes = scope.limit(MAX_NODES + 1).to_a
    raise CapacityExceeded if nodes.length > MAX_NODES
    @nodes = nodes.index_by(&:id)
    # Foreign IDs fail rather than silently affecting a local recall. Dormant
    # nodes are excluded; private active nodes still contribute to traversal.
    (@seed_ids + @activations.keys).uniq.each { |id| @vault.nodes.find(id) }
    @activations.select! { |id, _| @nodes.key?(id) }
    nodes.each { |node| @activations[node.id] = [ @activations.fetch(node.id, 0), node.baseline_activation ].max }
    @activations.select! { |_, value| value.positive? }
    return empty if nodes.empty?
    edges = @vault.edges.where(source_id: @nodes.keys, target_id: @nodes.keys).limit(MAX_EDGES + 1).to_a
    raise CapacityExceeded if edges.length > MAX_EDGES
    @adjacency = Hash.new { |hash, key| hash[key] = [] }
    edges.each do |edge|
      @adjacency[edge.source_id] << [ edge.target_id, edge.weight ]
      @adjacency[edge.target_id] << [ edge.source_id, edge.weight ] if SYMMETRIC_TYPES.include?(edge.edge_type)
    end
    vector = nil
    if @query.present?
      vector = Mnemodyne::Embeddings.embed(@query)
      seeds = nodes.select { |node| current_embedding?(node, vector) }
        .sort_by { |node| -Mnemodyne::Embeddings.cosine(vector, node.embedding) }.first(30)
    else
      seeds = @seed_ids.filter_map { |id| @nodes[id] }
    end
    starts = seeds.sample([ 5, seeds.length ].min, random: @random)
    visited = starts.map(&:id).to_set
    starts.each do |start|
      current = start.id
      3.times do
        choices = @adjacency[current].reject { |id, _| visited.include?(id) }
        weighted = choices.map do |id, weight|
          [ id, weight * (0.3 + 0.7 * @nodes.fetch(id).charge) * (1 + @activations.fetch(id, 0)) ]
        end
        total = weighted.sum(&:last)
        break unless total.positive?
        threshold = @random.rand * total
        chosen = weighted.find { |_, weight| threshold -= weight; threshold < 0 } || weighted.last
        current = chosen.first
        visited << current
      end
    end
    scored = visited.map do |id|
      node = @nodes.fetch(id)
      alignment = alignment(id)
      similarity = vector && current_embedding?(node, vector) ? Mnemodyne::Embeddings.cosine(vector, node.embedding) : 0.0
      { node: node, alignment: alignment, score: 0.4 * similarity + 0.3 * alignment + 0.3 * node.charge }
    end.sort_by { |row| -row[:score] }
    scored.select! { |row| row[:node].disclosure == "automatic" } if @automatic
    # One sample per relevance band, preserving the standalone walk's diversity.
    selected = if scored.length <= @limit
      scored
    else
      (0...@limit).map { |i| scored[(i * scored.length / @limit)...((i + 1) * scored.length / @limit)].sample(random: @random) }
    end
    intensity = Math.sqrt(@activations.values.sum { |value| value * value }).clamp(0, 1)
    max_alignment = selected.map { |row| row[:alignment] }.max.to_f
    deltas = selected.to_h { |row| [ row[:node].id, max_alignment.positive? ? 0.02 * intensity * row[:alignment] / max_alignment : 0.0 ] }
    recall_id = SecureRandom.uuid
    expires_at = 60.minutes.from_now
    receipt = verifier.generate({ "vault_id" => @vault.id, "recall_id" => recall_id, "deltas" => deltas,
      "generation" => @vault.recall_generation, "version" => VERSION, "expires_at" => expires_at.iso8601 }, expires_at: expires_at, purpose: "mnemodyne-use")
    { recall_id: recall_id, receipt: receipt, expires_at: expires_at.iso8601, algorithm_version: VERSION,
      results: selected.map { |row| serialize(row, deltas) } }
  end

  private

  def verifier
    Rails.application.message_verifier("mnemodyne-recall")
  end

  def current_embedding?(node, vector)
    node.embedding_profile == Mnemodyne::Embeddings.profile && node.embedding&.length == vector.length &&
      node.embedding_digest == Digest::SHA256.hexdigest(node.embedding_text)
  end

  def alignment(id)
    total = @activations.values.sum
    return 0.0 unless total.positive?
    # Multiple relation types to the same need must not multiply its activation.
    weights = @adjacency[id].group_by(&:first).transform_values { |entries| entries.map(&:last).max }
    weights.sum { |target, weight| weight * @activations.fetch(target, 0) } / total
  end

  def serialize(row, deltas)
    node = row[:node]
    { id: node.id, node_type: node.node_type, content: node.content, description: node.description,
      source_uris: node.source_uris, charge: node.charge, final_score: row[:score],
      would_apply_reinforcement: deltas.fetch(node.id) }
  end

  def empty
    { algorithm_version: VERSION, results: [] }
  end

end
