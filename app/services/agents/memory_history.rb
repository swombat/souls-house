module Agents
  class MemoryHistory
    KINDS = %w[journals day_summaries week_summaries month_summaries nodes].freeze
    PAGE_SIZE = 50
    class InvalidRequest < StandardError; end

    def initialize(agent, archive: MemoryArchive.new(agent))
      @agent, @archive = agent, archive
    end

    def call(kinds: KINDS, cursor: nil)
      raise InvalidRequest unless kinds.is_a?(Array) && (kinds - KINDS).empty?
      raise InvalidRequest unless cursor.nil? || (cursor.is_a?(String) && cursor.bytesize <= 4096)
      kinds = kinds.uniq.sort
      boundary = decode_cursor(cursor, kinds) if cursor.present?
      catalog = (kinds - [ "nodes" ]).any? ? @archive.catalog : { "status" => "not_requested", "items" => [] }
      entries = catalog.fetch("items").select { |item| kinds.include?(item["kind"]) }
      entries.select! { |item| (sort_key(item) <=> boundary) == -1 } if boundary
      entries = entries.sort_by { |item| sort_key(item) }.reverse.first(PAGE_SIZE + 1)
      nodes = kinds.include?("nodes") ? node_candidates(boundary) : []
      candidates = (entries + nodes).sort_by { |item| sort_key(item) }.reverse
      page = candidates.first(PAGE_SIZE)
      next_cursor = encode_cursor(sort_key(page.last), kinds) if candidates.size > PAGE_SIZE
      selections = page.reject { |item| item["kind"] == "nodes" }
      bodies = @archive.bodies(selections)
      {
        items: page.map do |item|
          if item["kind"] == "nodes"
            node_details(item)
          else
            item.slice("id", "kind", "occurred_at", "timestamp_basis", "title", "path")
              .merge(bodies.fetch(item["id"], { "body_status" => "unavailable" }))
          end
        end,
        next_cursor: next_cursor, archive_status: catalog["status"], measured_at: catalog["measured_at"]
      }
    end

    private

    def sort_key(item)
      time = item.fetch("occurred_at")
      # Put a day's consolidation above its entries without changing its displayed date.
      time = "#{time[0, 10]}T23:59:59.999999Z" if item["kind"] == "day_summaries"
      [ time, item.fetch("id") ]
    end

    def verifier = Rails.application.message_verifier("resident-memory-history-v2")
    def purpose(kinds) = "resident:#{@agent.id}:#{kinds.join(',')}"

    def encode_cursor(key, kinds)
      verifier.generate(key, purpose: purpose(kinds), expires_in: 1.day)
    end

    def decode_cursor(cursor, kinds)
      key = verifier.verified(cursor, purpose: purpose(kinds))
      raise InvalidRequest unless key.is_a?(Array) && key.length == 2 && key.all? { |part| part.is_a?(String) }
      Time.iso8601(key.first)
      key
    rescue ArgumentError
      raise InvalidRequest
    end

    def node_candidates(boundary)
      vault = @agent.memory_vault
      return [] unless vault
      scope = vault.nodes
      if boundary
        time, id = boundary
        # Journal ids start with a folder; node ids have an explicit prefix.
        node_id = id.delete_prefix("node:")
        if id.start_with?("node:")
          scope = scope.where("created_at < :time OR (created_at = :time AND id < :id)", time: Time.iso8601(time), id: node_id)
        else
          operator = "node:" < id ? "<=" : "<"
          scope = scope.where("created_at #{operator} ?", Time.iso8601(time))
        end
      end
      scope.order(created_at: :desc, id: :desc).limit(PAGE_SIZE + 1).map do |node|
        { "id" => "node:#{node.id}", "kind" => "nodes", "occurred_at" => node.created_at.utc.iso8601(6), "record" => node }
      end
    end

    def node_details(item)
      node = item.fetch("record")
      edges = @agent.memory_vault.edges.where("source_id = :id OR target_id = :id", id: node.id)
      count = edges.count
      details = edges.includes(:source, :target).order(created_at: :desc, id: :desc).limit(200).map do |edge|
        { id: edge.id, edge_type: edge.edge_type, weight: edge.weight,
          source: { id: edge.source_id, content: edge.source.content },
          target: { id: edge.target_id, content: edge.target.content } }
      end
      item.except("record").merge("timestamp_basis" => "created at", "title" => node.content,
        "node" => node.as_json(only: %i[id node_type content description charge integration_state disclosure is_dormant source_uris]),
        "edges" => details, "edge_count" => count, "edges_truncated" => count > details.size)
    end
  end
end
