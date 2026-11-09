class Mnemodyne::Recall

  VERSION = "house-v1"
  MAX_NODES = 5_000
  MAX_EDGES = 20_000
  SYMMETRIC_TYPES = %w[theme feeling reminds_of co_retrieved knows family colleague friend relates_to].freeze
  HUB_TYPES = %w[need person].freeze
  # Lexical channel: a query term found as a whole word in at most
  # LEXICAL_MAX_DF returnable memories reserves up to LEXICAL_SLOTS places
  # after the anchor. An embedding of one name doesn't single out the one
  # memory that contains it; a word match does.
  LEXICAL_SLOTS = 2
  LEXICAL_MAX_DF = 3
  LEXICAL_MAX_TERMS = 24
  SHORT_QUERY_WORDS = 3
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
    anchor_id = nil
    if @query.present?
      vector = Mnemodyne::Embeddings.embed(@query, input_type: :query)
      ranked = nodes.select { |node| current_embedding?(node, vector) }
        .sort_by { |node| -Mnemodyne::Embeddings.cosine(vector, node.embedding) }
      seeds = ranked.first(30)
      # With a query, the closest node that may be returned is the match and
      # comes first; gravity (charge, need alignment) orders and samples the
      # rest but must not displace it. Private nodes stay in the seed pool for
      # traversal and alignment, so the anchor is searched over the whole ranked
      # set: thirty private near-matches must not hide the eligible one. Before
      # this an exact-content query returned its own node about one time in six,
      # because only five random seeds were walked and scored.
      eligible = @automatic ? ranked.select { |node| node.disclosure == "automatic" } : ranked
      # A node whose text is the query is the match whatever the embedder says
      # (bge can put another memory closer to a node's content than the node,
      # whose vector also carries its description). Duplicates: closest, then id.
      wanted = normalize_text(@query)
      exact = nodes.select { |node| (!@automatic || node.disclosure == "automatic") && normalize_text(node.content) == wanted }
      exact = exact.sort_by { |node| [ current_embedding?(node, vector) ? -Mnemodyne::Embeddings.cosine(vector, node.embedding) : 1.0, node.id ] }
      anchor_id = (exact.first || eligible.first)&.id
    else
      seeds = @seed_ids.filter_map { |id| @nodes[id] }
    end
    starts = seeds.sample([ 5, seeds.length ].min, random: @random)
    starts = [ @nodes.fetch(anchor_id) ] + starts.reject { |node| node.id == anchor_id }.first([ starts.length - 1, 0 ].max) if anchor_id && starts.none? { |node| node.id == anchor_id }
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
    anchor_row = anchor_id && scored.find { |row| row[:node].id == anchor_id }
    reserved = [ anchor_row ].compact
    lexical_matches(except: reserved.map { |row| row[:node].id }).first(@limit - reserved.length).each do |node|
      reserved << (scored.find { |row| row[:node].id == node.id } || score_row(node, vector))
    end
    reserved_ids = reserved.map { |row| row[:node].id }.to_set
    rest = scored.reject { |row| reserved_ids.include?(row[:node].id) }
    # One sample per relevance band, preserving the standalone walk's diversity.
    selected = reserved + band_sample(rest, @limit - reserved.length)
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

  def normalize_text(text)
    text.to_s.unicode_normalize(:nfkc).downcase.split.join(" ")
  end

  def score_row(node, vector)
    alignment = alignment(node.id)
    similarity = vector && current_embedding?(node, vector) ? Mnemodyne::Embeddings.cosine(vector, node.embedding) : 0.0
    { node: node, alignment: alignment, score: 0.4 * similarity + 0.3 * alignment + 0.3 * node.charge }
  end

  # Returnable nodes containing the query's rarest whole-word terms, rarest
  # first. Hubs are never returned; automatic recall only returns automatic nodes.
  def lexical_matches(except: [])
    return [] if @query.blank?
    words = @query.scan(/[[:alnum:]][[:alnum:]_'-]*/)
    # A short query is probably a name: then two- and three-letter words count too.
    min_length = words.length <= SHORT_QUERY_WORDS ? 2 : 4
    terms = words.select { |word| word.length >= min_length }.map(&:downcase).uniq.max_by(LEXICAL_MAX_TERMS, &:length)
    return [] if terms.empty?
    pool = @nodes.values.reject { |node| HUB_TYPES.include?(node.node_type) || except.include?(node.id) }
    pool = pool.select { |node| node.disclosure == "automatic" } if @automatic
    texts = pool.to_h { |node| [ node.id, node.content.to_s.downcase ] }
    rare = terms.filter_map do |term|
      pattern = /(?<![[:alnum:]])#{Regexp.escape(term)}(?![[:alnum:]])/
      hits = pool.select { |node| texts[node.id].match?(pattern) }
      [ hits, hits.length ] if hits.length.between?(1, LEXICAL_MAX_DF)
    end.sort_by(&:last)
    picked = []
    rare.each do |hits, _|
      hits.sort_by { |node| -node.charge }.each { |node| picked << node unless picked.include?(node) }
      break if picked.length >= LEXICAL_SLOTS
    end
    picked.first(LEXICAL_SLOTS)
  end

  def band_sample(rows, count)
    return rows if rows.length <= count
    (0...count).map { |i| rows[(i * rows.length / count)...((i + 1) * rows.length / count)].sample(random: @random) }
  end

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
