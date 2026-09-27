class UnestimatedInteractionCosts

  def initialize(agents:)
    @agents = agents.index_by(&:id)
    @counts = Hash.new(0)
  end

  def add(interaction, cost)
    @counts[[ interaction.agent_id, interaction.model, cost[:note] ]] += 1
  end

  def rows
    @counts.map do |(agent_id, model, reason), count|
      {
        agent_name: @agents.fetch(agent_id).name,
        model: model.presence || "Unknown model",
        reason: reason,
        interaction_count: count
      }
    end.sort_by { |row| [ row[:agent_name].downcase, row[:model], row[:reason] ] }
  end

end
