module Agents::Portability
  # Relocation is intentionally separate from Checkpoint's same-owner restore.
  class GraphImport

    UUID = /\A[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\z/i

    def self.validate!(envelope, owner)
      raise Error, "Invalid graph checkpoint" unless envelope.is_a?(Hash) && envelope["payload"].is_a?(Hash)
      payload = envelope["payload"]
      digest = Digest::SHA256.hexdigest(JSON.generate(payload))
      raise Error, "Invalid graph checkpoint" unless envelope["sha256"] == digest && payload["version"] == Mnemodyne::Checkpoint::VERSION && payload["resident_uuid"] == owner
      nodes, edges, settings = payload.values_at("nodes", "edges", "settings")
      raise Error, "Invalid graph checkpoint" unless nodes.is_a?(Array) && edges.is_a?(Array) && settings.is_a?(Hash) && nodes.length + edges.length <= Archive::MAX_ENTRIES
      raise Error, "Invalid graph settings" unless [ true, false ].include?(settings["auto_preview_enabled"])
      vault = Mnemodyne::Vault.new(id: SecureRandom.uuid, agent: Agent.new(uuid: owner), **settings.slice("auto_preview_enabled", "decay_rate", "charge_decay_rate", "charge_decay_floor").symbolize_keys)
      raise Error, "Invalid graph settings" unless vault.valid?
      index = {}
      nodes.each do |attributes|
        raise Error, "Invalid graph node" unless attributes.is_a?(Hash) && attributes["id"].is_a?(String) && attributes["id"].match?(UUID) && !index.key?(attributes["id"]) && (attributes.keys - Mnemodyne::Checkpoint::NODE_FIELDS).empty?
        node = Mnemodyne::Node.new(attributes.merge("vault" => vault))
        raise Error, "Invalid graph node" unless node.valid?
        index[node.id] = node
      end
      ids, relations, hubs = {}, {}, {}
      nodes.each do |node|
        next unless node["node_type"].in?(%w[person need])
        key = [ node["node_type"], node["content"].downcase ]
        raise Error, "Duplicate graph hub" if hubs[key]
        hubs[key] = true
      end
      edges.each do |attributes|
        raise Error, "Invalid graph edge" unless attributes.is_a?(Hash) && attributes["id"].is_a?(String) && attributes["id"].match?(UUID) && !ids[attributes["id"]] && (attributes.keys - Mnemodyne::Checkpoint::EDGE_FIELDS).empty?
        source, target = index.values_at(attributes["source_id"], attributes["target_id"])
        edge = Mnemodyne::Edge.new(attributes.merge("vault" => vault, "source" => source, "target" => target))
        key = attributes.values_at("source_id", "target_id", "edge_type")
        raise Error, "Invalid graph edge" unless source && target && edge.valid? && !relations[key]
        ids[edge.id] = relations[key] = true
      end
      true
    rescue ActiveRecord::ActiveRecordError, ArgumentError, TypeError
      raise Error, "Invalid graph checkpoint"
    end

    def self.call(agent, envelope, source_installation:)
      validate!(envelope, envelope.dig("payload", "resident_uuid"))
      payload = envelope.fetch("payload").deep_dup
      mapping = payload["nodes"].to_h { |node| [ node["id"], SecureRandom.uuid ] }
      edge_mapping = {}
      uri_mapping = {}
      payload["nodes"].each do |node|
        old_id = node["id"]
        node["source_uris"] = node.fetch("source_uris", []).map do |uri|
          next uri unless uri.start_with?("house://")
          relocated = "archive-house://#{source_installation}/#{uri.delete_prefix('house://')}"
          relocated = "archive-house://#{source_installation}/sha256/#{Digest::SHA256.hexdigest(uri)}" if relocated.length > 2_000
          (uri_mapping[old_id] ||= {})[uri] = relocated
          relocated
        end
        node["id"] = mapping.fetch(old_id)
      end
      payload["edges"].each do |edge|
        old = edge["id"]
        edge["id"] = edge_mapping[old] = SecureRandom.uuid
        edge["source_id"] = mapping.fetch(edge["source_id"])
        edge["target_id"] = mapping.fetch(edge["target_id"])
      end
      payload["resident_uuid"] = agent.uuid
      relocated = { "payload" => payload, "sha256" => Digest::SHA256.hexdigest(JSON.generate(payload)) }
      vault = agent.create_memory_vault!(suspended_at: Time.current)
      Mnemodyne::Checkpoint.import(vault, relocated)
      { "nodes" => mapping, "edges" => edge_mapping, "source_uris" => uri_mapping }
    end

  end
end
