# One resident-authored handle and its connections, inside Write's per-vault
# transaction. No generated prose, inferred needs, or updates to existing hubs.
class Mnemodyne::Formation

  NODE_FIELDS = %w[node_type content description charge disclosure source_uris metadata].freeze
  CONNECTION_FIELDS = %w[target_id target edge_type weight].freeze
  MAX_CONNECTIONS = 20

  def initialize(vault, payload)
    @vault, @payload = vault, payload
  end

  def call
    object!(@payload, %w[memory connections])
    attributes = object!(@payload.fetch("memory"), NODE_FIELDS)
    raise ArgumentError unless attributes.fetch("node_type", "memory") == "memory"
    raise ArgumentError unless attributes["source_uris"].is_a?(Array) && attributes["source_uris"].any?
    connections = @payload.fetch("connections", [])
    raise ArgumentError unless connections.is_a?(Array) && connections.size <= MAX_CONNECTIONS

    node = @vault.nodes.create!(attributes.merge("node_type" => "memory"))
    edges = connections.map do |connection|
      object!(connection, CONNECTION_FIELDS)
      raise ArgumentError unless connection.key?("target_id") ^ connection.key?("target")
      target = if connection.key?("target_id")
        id = connection.fetch("target_id")
        raise ArgumentError unless id.is_a?(String) && id.match?(/\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i)
        @vault.nodes.find(id)
      else
        hub(connection.fetch("target"))
      end
      raise Mnemodyne::Write::Conflict if target.is_dormant?
      @vault.edges.create!(
        source: node, target: target,
        edge_type: connection.fetch("edge_type"), weight: connection.fetch("weight", 0.5)
      )
    end
    {
      node: node.as_json(except: [ :vault_id, :embedding, :embedding_digest ]),
      connections: edges.map { |edge| { id: edge.id, target_id: edge.target_id, edge_type: edge.edge_type } }
    }
  end

  private

  def object!(value, allowed)
    raise ArgumentError unless value.is_a?(Hash) && (value.keys - allowed).empty?
    value
  end

  def hub(attributes)
    object!(attributes, NODE_FIELDS)
    raise ArgumentError unless attributes["node_type"].in?(%w[person need])
    content = attributes.fetch("content")
    raise ArgumentError unless content.is_a?(String) && content.present?
    @vault.nodes.where(node_type: attributes.fetch("node_type"))
      .find_by("LOWER(content) = ?", content.downcase) || @vault.nodes.create!(attributes)
  end

end
