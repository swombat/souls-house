class AgentInteractionCostReport

  DEFAULT_DAY_LIMIT = 30

  def initialize(agent:)
    @agent = agent
  end

  def call
    daily_costs = Hash.new do |hash, date|
      hash[date] = {
        amount: BigDecimal("0"),
        interaction_count: 0,
        subscription_estimate: BigDecimal("0"),
        subscription_interaction_count: 0
      }
    end
    pricing_dates = []
    interaction_count = 0
    unestimated = UnestimatedInteractionCosts.new(agents: [ agent ])

    agent.agent_runtime_interactions.find_each do |interaction|
      cost = interaction.estimated_cost
      unless cost[:amount_usd]
        unestimated.add(interaction, cost)
        next
      end

      date = interaction.started_at.in_time_zone.to_date
      if interaction.subscription_based?
        daily_costs[date][:subscription_estimate] += BigDecimal(cost[:amount_usd])
        daily_costs[date][:subscription_interaction_count] += 1
      else
        daily_costs[date][:amount] += BigDecimal(cost[:amount_usd])
        daily_costs[date][:interaction_count] += 1
        interaction_count += 1
      end
      pricing_dates << cost[:pricing_as_of] if cost[:pricing_as_of]
    end

    days = daily_costs.sort_by { |date, _| date }.reverse.first(DEFAULT_DAY_LIMIT).map do |date, values|
      {
        date: date.iso8601,
        amount_usd: values[:amount].to_s("F"),
        interaction_count: values[:interaction_count],
        subscription_estimate_usd: values[:subscription_estimate].zero? ? nil : values[:subscription_estimate].to_s("F"),
        subscription_interaction_count: values[:subscription_interaction_count]
      }
    end

    {
      total_amount_usd: days.any? ? daily_costs.values.sum { |values| values[:amount] }.to_s("F") : nil,
      subscription_estimate_usd: subscription_estimate_total(daily_costs),
      interaction_count: interaction_count,
      subscription_interaction_count: daily_costs.values.sum { |values| values[:subscription_interaction_count] },
      pricing_as_of: pricing_dates.max,
      unestimated: unestimated.rows,
      days: days
    }
  end

  private

  attr_reader :agent

  def subscription_estimate_total(daily_costs)
    total = daily_costs.values.sum { |values| values[:subscription_estimate] }
    total.zero? ? nil : total.to_s("F")
  end

end
