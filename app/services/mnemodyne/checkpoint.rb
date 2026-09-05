class Mnemodyne::Checkpoint

  VERSION = 1
  MAX_BYTES = 50_000_000
  class Invalid < StandardError; end
  NODE_FIELDS = %w[id node_type content description charge integration_state is_dormant source_uris metadata disclosure created_at updated_at].freeze
  EDGE_FIELDS = %w[id source_id target_id edge_type weight metadata created_at updated_at].freeze

  def self.export(vault)
    raise Invalid if vault.agent.uuid.blank?
    vault.with_lock do
      payload = {
        "version" => VERSION, "resident_uuid" => vault.agent.uuid,
        "exported_at" => Time.current.iso8601, "algorithm_version" => Mnemodyne::Recall::VERSION,
        "embedding_profile" => Mnemodyne::Embeddings.profile,
        "settings" => { "auto_preview_enabled" => vault.auto_preview_enabled, "decay_rate" => vault.decay_rate },
        "nodes" => vault.nodes.order(:id).map { |node| node.attributes.slice(*NODE_FIELDS).as_json },
        "edges" => vault.edges.order(:id).map { |edge| edge.attributes.slice(*EDGE_FIELDS).as_json }
      }
      body = JSON.generate(payload)
      raise Invalid if body.bytesize > MAX_BYTES
      { "payload" => payload, "sha256" => Digest::SHA256.hexdigest(body) }
    end
  end

  # Normal import requires an empty vault. Restore replacement is deliberately
  # privileged and requires suspension; validation and writes share a transaction.
  def self.import(vault, envelope, replace: false)
    raise Invalid unless envelope.is_a?(Hash) && envelope["payload"].is_a?(Hash) && envelope["sha256"].is_a?(String)
    payload = envelope.fetch("payload")
    digest = Digest::SHA256.hexdigest(JSON.generate(payload))
    raise Invalid unless ActiveSupport::SecurityUtils.secure_compare(digest, envelope.fetch("sha256"))
    raise Invalid unless payload["version"] == VERSION && payload["resident_uuid"].present? && payload["resident_uuid"] == vault.agent.uuid
    nodes, edges, settings = payload.values_at("nodes", "edges", "settings")
    raise Invalid unless nodes.is_a?(Array) && edges.is_a?(Array) && settings.is_a?(Hash)
    raise Invalid if JSON.generate(payload).bytesize > MAX_BYTES
    vault.with_lock do
      if replace
        raise Invalid unless vault.suspended_at?
        Mnemodyne::Use.where(vault_id: vault.id).delete_all
        Mnemodyne::Operation.where(vault_id: vault.id).delete_all
        Mnemodyne::Edge.where(vault_id: vault.id).delete_all
        Mnemodyne::Node.where(vault_id: vault.id).delete_all
      else
        raise Invalid if vault.nodes.exists? || vault.edges.exists? || vault.operations.exists?
      end
      # insert_all is intentionally not used: validate all imported graph values.
      nodes.each do |attributes|
        raise Invalid unless attributes.is_a?(Hash) && attributes["id"].is_a?(String)
        node = vault.nodes.new(attributes.slice(*NODE_FIELDS))
        node.save!
      end
      edges.each do |attributes|
        raise Invalid unless attributes.is_a?(Hash)
        vault.edges.create!(attributes.slice(*EDGE_FIELDS))
      end
      automatic = settings.fetch("auto_preview_enabled")
      raise Invalid unless [ true, false ].include?(automatic)
      vault.update!(auto_preview_enabled: automatic, decay_rate: settings.fetch("decay_rate"), recall_generation: vault.recall_generation + 1)
    end
    { imported: true, nodes: nodes.length, edges: edges.length }
  rescue KeyError, TypeError, ActiveRecord::ActiveRecordError, ArgumentError
    raise Invalid
  end

end
