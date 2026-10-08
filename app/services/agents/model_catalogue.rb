module Agents
  # The models a resident can be given, grouped as the resident pages show them.
  module ModelCatalogue

    def self.grouped
      (Chat::MODELS + HouseInference::Offering.models).group_by { |m| m[:group] || "Other" }.transform_values do |models|
        models.map do |m|
          reasoning = Chat.reasoning_effort_config(m[:model_id])
          {
            model_id: m[:model_id],
            label: m[:label],
            supports_thinking: m.dig(:thinking, :supported) == true,
            reasoning:
          }
        end
      end
    end

  end
end
