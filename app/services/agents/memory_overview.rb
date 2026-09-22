module Agents
  class MemoryOverview
    def initialize(agent, archive: MemoryArchive.new(agent), today: Time.current.utc.to_date)
      @agent, @archive, @today = agent, archive, today
    end

    def call
      journals = @archive.overview
      vault = @agent.memory_vault
      nodes = vault ? vault.nodes : Mnemodyne::Node.none
      edges = vault ? vault.edges : Mnemodyne::Edge.none
      dates = ((@today - 13)..@today).map(&:iso8601)
      node_counts = additions(nodes)
      edge_counts = additions(edges)
      {
        journals: journals.slice("status", "count", "measured_at"),
        node_count: nodes.count, edge_count: edges.count,
        days: dates.map do |date|
          { date: date, journals: journals.fetch("daily_counts", {}).fetch(date, 0),
            nodes: node_counts.fetch(date, 0), edges: edge_counts.fetch(date, 0) }
        end
      }
    end

    private

    def additions(scope)
      from = Time.utc(@today.year, @today.month, @today.day) - 13.days
      scope.where(created_at: from...(from + 14.days))
        .group(Arel.sql("(created_at AT TIME ZONE 'UTC')::date"))
        .count.transform_keys(&:iso8601)
    end
  end
end
