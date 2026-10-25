class ExternalAgentMemoryAggregationJob < ApplicationJob

  queue_as :default

  def perform(period, target = nil)
    period = period.to_s
    target ||= default_target_for(period)

    aggregatable_agents.find_each do |agent|
      ExternalAgentMemoryAggregationRequest.new(
        agent: agent,
        period: period,
        target: target
      ).call
    end
  end

  private

  def aggregatable_agents
    Agent.active
         .unpaused
         .not_billing_held
         .where(runtime: "external")
         .where.not(trigger_bearer_token: [ nil, "" ])
  end

  def default_target_for(period)
    case period
    when "daily"
      1.day.ago.to_date.iso8601
    when "weekly"
      1.week.ago.to_date.beginning_of_week.iso8601
    when "monthly"
      1.month.ago.to_date.strftime("%Y-%m")
    else
      raise ArgumentError, "unknown memory aggregation period: #{period}"
    end
  end

end
