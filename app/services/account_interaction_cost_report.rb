class AccountInteractionCostReport

  DEFAULT_DAY_LIMIT = 30

  def initialize(account:)
    @account = account
  end

  def call
    daily_costs = Hash.new do |dates, date|
      dates[date] = Hash.new { |agents, agent_id| agents[agent_id] = BigDecimal("0") }
    end
    daily_subscription_estimates = Hash.new do |dates, date|
      dates[date] = Hash.new { |agents, agent_id| agents[agent_id] = BigDecimal("0") }
    end
    totals = Hash.new { |agents, agent_id| agents[agent_id] = BigDecimal("0") }
    subscription_estimates = Hash.new { |agents, agent_id| agents[agent_id] = BigDecimal("0") }
    pricing_dates = []
    unestimated = UnestimatedInteractionCosts.new(agents: account.agents)

    interactions.find_each do |interaction|
      cost = interaction.estimated_cost
      unless cost[:amount_usd]
        unestimated.add(interaction, cost)
        next
      end

      amount = BigDecimal(cost[:amount_usd])
      date = interaction.started_at.in_time_zone.to_date
      if interaction.subscription_based?
        daily_subscription_estimates[date][interaction.agent_id] += amount
        subscription_estimates[interaction.agent_id] += amount
      else
        daily_costs[date][interaction.agent_id] += amount
        totals[interaction.agent_id] += amount
      end
      pricing_dates << cost[:pricing_as_of] if cost[:pricing_as_of]
    end

    included_agent_ids = totals.keys | subscription_estimates.keys
    agents = account.agents.select { |agent| included_agent_ids.include?(agent.id) }.sort_by { |agent| agent.name.downcase }
    dates = (daily_costs.keys | daily_subscription_estimates.keys).sort.reverse.first(DEFAULT_DAY_LIMIT)
    days = dates.map do |date|
      costs = daily_costs[date]
      subscription_costs = daily_subscription_estimates[date]
      {
        date: date.iso8601,
        agent_costs: agents.to_h do |agent|
          amount = costs[agent.id]
          [ agent.to_param, amount.zero? ? nil : amount.to_s("F") ]
        end,
        agent_subscription_estimates: agents.to_h do |agent|
          amount = subscription_costs[agent.id]
          [ agent.to_param, amount.zero? ? nil : amount.to_s("F") ]
        end,
        total_amount_usd: costs.values.sum.to_s("F"),
        subscription_estimate_usd: optional_amount(subscription_costs.values.sum)
      }
    end

    {
      agents: agents.map { |agent| { id: agent.to_param, name: agent.name } },
      days: days,
      agent_totals: agents.to_h { |agent| [ agent.to_param, totals[agent.id].to_s("F") ] },
      agent_subscription_estimates: agents.to_h do |agent|
        [ agent.to_param, optional_amount(subscription_estimates[agent.id]) ]
      end,
      total_amount_usd: included_agent_ids.any? ? totals.values.sum.to_s("F") : nil,
      subscription_estimate_usd: optional_amount(subscription_estimates.values.sum),
      pricing_as_of: pricing_dates.max,
      unestimated: unestimated.rows
    }
  end

  private

  attr_reader :account

  def interactions
    AgentRuntimeInteraction.where(agent_id: account.agent_ids)
  end

  def optional_amount(amount)
    amount.zero? ? nil : amount.to_s("F")
  end

end
